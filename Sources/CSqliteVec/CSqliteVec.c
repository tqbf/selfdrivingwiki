/* CSqliteVec — registers the statically-linked sqlite-vec extension on a
 * connection, against the SYSTEM libsqlite3 (no load_extension). */
#include "CSqliteVec.h"
#include <stddef.h>   // NULL

/* sqlite3.h / sqlite3ext.h come from the macOS SDK (system). sqlite-vec.h
 * resolves its SQLite dependency through them under -DSQLITE_CORE. */
#include "sqlite3.h"
#include "sqlite-vec.h"

int wikifs_vec_register(void *db) {
    /* sqlite3_vec_init(db, pzErrMsg, pApi). Under SQLITE_CORE the pApi argument
     * (the sqlite3_api_routines indirection used by *loadable* extensions) is a
     * no-op, so NULL is correct and safe. */
    return sqlite3_vec_init((sqlite3 *)db, NULL, NULL);
}
