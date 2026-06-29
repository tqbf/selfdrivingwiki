#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H

#ifdef __cplusplus
extern "C" {
#endif

/// Register the sqlite-vec module (`vec0`) and scalar functions
/// (`vec_distance_cosine`, `vec_distance_l2`, `vec_quantize_*`, ...) on a SQLite
/// connection. `db` is a `sqlite3*` passed as `void*` to avoid pulling sqlite3.h
/// into this public header. Returns SQLITE_OK (0) on success.
///
/// sqlite-vec is linked STATICALLY (`-DSQLITE_CORE`) against the system
/// libsqlite3, so this works WITHOUT `sqlite3_load_extension` — which the macOS
/// system SQLite omits (`SQLITE_OMIT_LOAD_EXTENSION`). Call once per connection.
int wikifs_vec_register(void *db);

#ifdef __cplusplus
}
#endif

#endif /* CSQLITEVEC_H */
