# CSqliteVec — statically-linked [sqlite-vec](https://github.com/asg017/sqlite-vec)

Registers sqlite-vec (`vec0` virtual table + scalar distance functions like
`vec_distance_cosine`) on a SQLite connection, **without `sqlite3_load_extension`**.

## Why this exists

macOS's **system** SQLite is built with `SQLITE_OMIT_LOAD_EXTENSION`, so the
`sqlite3_enable_load_extension` / `sqlite3_load_extension` symbols don't exist —
the loadable `vec0.dylib` cannot be loaded against it (dlsym returns NULL). This
target compiles the sqlite-vec **amalgamation** with `-DSQLITE_CORE`, which makes
the `SQLITE_EXTENSION_INIT1/2` macros no-ops so sqlite-vec calls the system
`sqlite3_*` symbols directly. We then register it per-connection via
`sqlite3_vec_init(db, NULL, NULL)` (exposed to Swift as `wikifs_vec_register`).

The app keeps using the **system** SQLite (`import SQLite3`) everywhere — only the
vec extension is vendored. `sqlite3.h` / `sqlite3ext.h` come from the macOS SDK
(version-matched to the runtime); `libsqlite3` is the system library.

## Provenance

- **Version:** sqlite-vec `v0.1.9` (`SQLITE_VEC_VERSION`)
- **Upstream source commit:** `e9f598abfa0c06b328d8fe5da9c3760cce74be10`
  (`SQLITE_VEC_SOURCE` in `sqlite-vec.h`)
- **Downloaded from:** the `sqlite-vec-0.1.9-amalgamation.tar.gz` release asset
  at https://github.com/asg017/sqlite-vec/releases/tag/v0.1.9
- Files: `sqlite-vec.c`, `sqlite-vec.h` (unchanged from the amalgamation).

## License

sqlite-vec is **dual-licensed: MIT or Apache-2.0** (your choice). This repo
vendored the MIT text in `LICENSE` (Copyright (c) 2024 Alex Garcia).

## How to build (repeatable)

Nothing manual — `swift build` / `make` compiles `sqlite-vec.c` with the
`-DSQLITE_CORE -DSQLITE_VEC_STATIC` settings declared in `Package.swift`
(`CSqliteVec` target). No build-time download, no dylib. Any contributor with
Xcode/CLT can build it.

## Upgrading sqlite-vec

1. Download the new `sqlite-vec-<ver>-amalgamation.tar.gz` from the releases page.
2. Replace `sqlite-vec.c` and `sqlite-vec.h` here with the extracted copies.
3. Update the version/commit lines above (from `sqlite-vec.h`).
4. `swift build && swift test`.
