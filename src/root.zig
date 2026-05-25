const std = @import("std");
const ztorm = @import("ztorm");
const driver = ztorm.driver;
const ColumnValue = driver.ColumnValue;
const Driver = driver.Driver;
const Param = driver.Param;
const Row = driver.Row;
const Rows = driver.Rows;
const Error = driver.Error;
const Allocator = std.mem.Allocator;

const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

comptime {
    if (!@import("builtin").link_libc) {
        @compileError("ztorm_sqlite requires libc - perhaps you forgot to link it in build.zig?");
    }
}

/// Internal connection context. One per open() call.
///
/// Heap-alloc'd and freed by closeFn when the Driver is closed.
const SqliteContext = struct {
    db: *sqlite.sqlite3,
    allocator: Allocator,
};

/// Internal statement context. One per query() call.
///
/// Holds the prepared statement for the duration of a Rows iteration.
///
/// Freed by rowsClose() - always call Rows.close() when done iterating.
const SqliteRows = struct {
    statement: *sqlite.sqlite3_stmt,
    allocator: Allocator,
    done: bool,
};

// -- Row callbacks --

/// Reads the value at `index` from the current statement row.
/// Text and blob values are copied into driver-owned memory so the
/// caller does not need to worry about SQLite's internal buffer lifetime.
///
/// Returns .null on allocation failure rather than propagating the error,
/// since getColumnFn has no error return - callers should treat unexpected
/// nulls as a sign of memory pressure.
fn getColumn(ctx: *anyopaque, index: usize) ColumnValue {
    const rows: *SqliteRows = @ptrCast(@alignCast(ctx));
    const i: c_int = @intCast(index);

    return switch (sqlite.sqlite3_column_type(rows.statement, i)) {
        sqlite.SQLITE_INTEGER => .{ .int = sqlite.sqlite3_column_int64(rows.statement, i) },
        sqlite.SQLITE_FLOAT => .{ .float = sqlite.sqlite3_column_double(rows.statement, i) },
        sqlite.SQLITE_NULL => .null,

        sqlite.SQLITE_TEXT => blk: {
            const ptr = sqlite.sqlite3_column_text(rows.statement, i);
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(rows.statement, i));
            const raw = ptr[0..len];
            // dupe into driver-owned memory
            // freed when rows.close() is called
            // valid until the next sqlite3_step or sqlite3_finalize
            const copy = rows.allocator.dupe(u8, raw) catch return .null;
            break :blk .{ .text = copy };
        },

        sqlite.SQLITE_BLOB => blk: {
            const ptr: [*]const u8 = @ptrCast(sqlite.sqlite3_column_blob(rows.statement, i));
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(rows.statement, i));
            const raw = ptr[0..len];
            // same thing as the TEXT type
            const copy = rows.allocator.dupe(u8, raw) catch return .null;
            break :blk .{ .blob = copy };
        },

        // SQLite should never return anything outside the above set,
        // but defensive is better than undefined behaviour.
        else => .null,
    };
}

/// Returns the number of columns in the current statement row.
fn columnCount(ctx: *anyopaque) usize {
    const rows: *SqliteRows = @ptrCast(@alignCast(ctx));
    return @intCast(sqlite.sqlite3_column_count(rows.statement));
}

// -- Rows callbacks --

/// Advances the statement to the next row.
/// Returns null when the result set is exhausted (SQLITE_DONE).
/// The returned Row's ctx pointer aliases this SqliteRows - do not
/// call .next() or .close() while holding a Row reference.
fn rowsNext(ctx: *anyopaque) Error!?Row {
    const rows: *SqliteRows = @ptrCast(@alignCast(ctx));

    if (rows.done) return null;

    const result_code = sqlite.sqlite3_step(rows.statement);
    switch (result_code) {
        sqlite.SQLITE_ROW => return Row{
            .getColumnFn = getColumn,
            .columnCountFn = columnCount,
            .ctx = ctx,
        },
        sqlite.SQLITE_DONE => {
            rows.done = true;
            return null;
        },
        else => return Error.StepFailed,
    }
}

/// Finalizes the prepared statement and frees the SqliteRows allocation.
/// Must be called once per query() call, even if iteration was
/// cut short. After this call the Rows value is destroyed.
fn rowsClose(ctx: *anyopaque) void {
    const rows: *SqliteRows = @ptrCast(@alignCast(ctx));
    _ = sqlite.sqlite3_finalize(rows.statement);
    rows.allocator.destroy(rows);
}

// -- Driver callbacks --

/// Binds `params` to `statement` in order. Indices are 1-based as SQLite requires.
/// SQLITE_STATIC is used for text and blob.
fn bindParams(statement: *sqlite.sqlite3_stmt, params: []const Param) Error!void {
    for (params, 0..) |param, i| {
        const index: c_int = @intCast(i + 1); // SQLite bind indices are 1-based
        const result_code = switch (param) {
            .int => |v| sqlite.sqlite3_bind_int64(statement, index, v),
            .float => |v| sqlite.sqlite3_bind_double(statement, index, v),
            .text => |v| sqlite.sqlite3_bind_text(statement, index, v.ptr, @intCast(v.len), sqlite.SQLITE_STATIC),
            .blob => |v| sqlite.sqlite3_bind_blob(statement, index, v.ptr, @intCast(v.len), sqlite.SQLITE_STATIC),
            .bool => |v| sqlite.sqlite3_bind_int(statement, index, if (v) 1 else 0),
            .null => sqlite.sqlite3_bind_null(statement, index),
        };
        if (result_code != sqlite.SQLITE_OK) return Error.BindFailed;
    }
}

/// Executes a statement that produces no result rows (INSERT, UPDATE, DELETE, DDL).
/// Prepares, binds, steps, and finalizes in a single call.
/// Use query() instead for SELECT statements.
///
/// See also:
/// * `query()`
fn execute(ctx: *anyopaque, sql: []const u8, params: []const Param) Error!void {
    const conn: *SqliteContext = @ptrCast(@alignCast(ctx));
    var statement: ?*sqlite.sqlite3_stmt = null;

    if (sqlite.sqlite3_prepare_v2(conn.db, sql.ptr, @intCast(sql.len), &statement, null) != sqlite.SQLITE_OK)
        return Error.PrepareFailed;
    defer _ = sqlite.sqlite3_finalize(statement);

    try bindParams(statement.?, params);

    const result_code = sqlite.sqlite3_step(statement.?);
    if (result_code != sqlite.SQLITE_DONE and result_code != sqlite.SQLITE_ROW) return Error.StepFailed;
}

/// Prepares a SELECT statement and returns a Rows iterator.
/// The prepared statement is kept alive until Rows.close() is called -
/// the caller is responsible for always calling close(), typically via defer.
fn query(ctx: *anyopaque, sql: []const u8, params: []const Param) Error!Rows {
    const conn: *SqliteContext = @ptrCast(@alignCast(ctx));
    var statement: ?*sqlite.sqlite3_stmt = null;

    if (sqlite.sqlite3_prepare_v2(conn.db, sql.ptr, @intCast(sql.len), &statement, null) != sqlite.SQLITE_OK)
        return Error.PrepareFailed;

    try bindParams(statement.?, params);

    // lives until rowsClose() frees it
    const rows = try conn.allocator.create(SqliteRows);
    rows.* = .{
        .statement = statement.?,
        .allocator = conn.allocator,
        .done = false,
    };

    return Rows{
        .nextFn = rowsNext,
        .closeFn = rowsClose,
        .ctx = rows,
    };
}

/// Closes the SQLite connection and frees the SqliteContext allocation.
/// After this call the Driver is invalid — do NOT call any other function on it.
fn close(ctx: *anyopaque) void {
    const conn: *SqliteContext = @ptrCast(@alignCast(ctx));
    _ = sqlite.sqlite3_close(conn.db);
    conn.allocator.destroy(conn);
}

// -- Public API --

/// Opens a SQLite database at `path` and returns a Driver handle.
/// Pass ":memory:" as path for an in-memory database.
///
/// The driver owns `allocator` for the lifetime of the connection -
/// use the same allocator to avoid fragmentation.
/// Call Driver.close() when done to release the connection and all memory.
///
/// Example:
/// ```zig
///   const driver = try zt_sqlite.open(allocator, "app.db");
///   defer driver.close();
///   var db = ztorm.DB(ztorm.dialect.SQLite).init(driver);
/// ```
pub fn open(allocator: Allocator, path: [:0]const u8) Error!Driver {
    var db: ?*sqlite.sqlite3 = null;

    if (sqlite.sqlite3_open(path.ptr, &db) != sqlite.SQLITE_OK)
        return Error.OpenFailed;

    const conn = try allocator.create(SqliteContext);
    conn.* = .{
        .db = db.?,
        .allocator = allocator,
    };

    return Driver{
        .executeFn = execute,
        .queryFn = query,
        .closeFn = close,
        .ctx = conn,
    };
}
