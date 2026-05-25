# ztorm_sqlite

**SQLite** driver for [ztorm](https://github.com/ItzNikDi/ztorm).

---

## Requirements

- `sqlite3` installation
- `ztorm` in your `build.zig.zon`

On Debian/Ubuntu and derivatives:
```shell
apt install libsqlite3-dev
```

On Arch-based systems:
```shell
pacman -S sqlite
```

On macOS:
```shell
brew install sqlite3
```

On Windows, grab a precompiled binary from the [download link](https://sqlite.org/download.html).

---

## Installation

### 0. Add ztorm by following its steps first - those are found [here](https://github.com/ItzNikDi/ztorm);

### 1. Add dependency
```shell
zig fetch --save "git+https://github.com/ItzNikDi/ztorm_sqlite.git#main"
```

### 2. Wire up `build.zig`

```zig
const ztorm = b.dependency("ztorm", .{
    .target = target,
    .optimize = optimize,
});

const zt_sqlite = b.dependency("ztorm_sqlite", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("ztorm", ztorm.module("ztorm"));
exe.root_module.addImport("ztorm_sqlite", zt_sqlite.module("ztorm_sqlite"));
```

libc and `sqlite3` are linked automatically - nothing extra needed in your `build.zig`.

---

## Usage

```zig
const ztorm  = @import("ztorm");
const zt_sqlite = @import("ztorm_sqlite");

const driver = try zt_sqlite.open(allocator, "app.db");
defer driver.close();

var db = ztorm.DB(ztorm.dialect.SQLite).init(driver);
```

Pass `":memory:"` instead for an in-memory database:

```zig
const driver = try zt_sqlite.open(allocator, ":memory:");
```

---

## Notes

- A single `Driver` instance is not thread-safe. Use one per thread or guard
  with a mutex.
- Text and blob values returned from queries are owned by the driver and valid
  until the next `Rows.next()` or `Rows.close()` call. Dupe them if they need to outlive the current iteration.

---