import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy bound text/blob immediately. We must
/// NEVER use `SQLITE_STATIC` for Swift `String` bytes: the temporary buffer the
/// `String` exposes can be freed before `sqlite3_step`, leaving SQLite reading
/// freed memory. The transient destructor is `(sqlite3_destructor_type)(-1)`.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over a prepared `sqlite3_stmt`. One instance per distinct SQL
/// string; reused across calls via `reset()` (which clears bindings). Owned and
/// finalized by `SQLiteWikiStore`.
final class SQLiteStatement {
    private let db: OpaquePointer
    private(set) var handle: OpaquePointer?

    init(db: OpaquePointer, sql: String) throws {
        self.db = db
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, handle != nil else {
            throw WikiStoreError.sqlite(code: rc, message: Self.message(db))
        }
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Reset the statement for reuse and drop previous bindings.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    // MARK: - Binding (1-based indexes, per the SQLite C API)

    func bind(_ value: String, at index: Int32) throws {
        let rc = sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT)
        try check(rc)
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(handle, index, value))
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    /// Bind raw bytes as a BLOB. `SQLITE_TRANSIENT` makes SQLite copy the bytes
    /// immediately (same reasoning as the text binder): the `Data` buffer the
    /// closure exposes is only valid for the call, so SQLite must not retain a
    /// pointer into it past `sqlite3_step`.
    func bind(_ data: Data, at index: Int32) throws {
        let rc = data.withUnsafeBytes { raw -> Int32 in
            sqlite3_bind_blob(handle, index, raw.baseAddress,
                              Int32(raw.count), SQLITE_TRANSIENT)
        }
        try check(rc)
    }

    // MARK: - Stepping

    /// Step once. Returns true on `SQLITE_ROW`, false on `SQLITE_DONE`.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw WikiStoreError.sqlite(code: rc, message: Self.message(db))
        }
    }

    // MARK: - Column readers (0-based)

    func text(at column: Int32) -> String {
        guard let base = sqlite3_column_text(handle, column) else { return "" }
        // `String(cString:)` TRAPS on invalid UTF-8 and stops at an embedded NUL.
        // DB text (e.g. processed source markdown) can carry arbitrary bytes —
        // either genuinely bad data or garbage from a racing statement read — so
        // decode by explicit byte length and fall back to a lossy decode (U+FFFD)
        // rather than crashing the process.
        let byteCount = Int(sqlite3_column_bytes(handle, column))
        guard byteCount > 0 else { return "" }
        let buffer = UnsafeBufferPointer(start: base, count: byteCount)
        return String(bytes: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func int(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    /// Read a BLOB column as `Data`. Returns empty `Data` for a NULL/zero-length
    /// column. The bytes are copied out of SQLite's buffer immediately (the
    /// pointer is only valid until the next step/reset).
    func blob(at column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let ptr = sqlite3_column_blob(handle, column) else {
            return Data()
        }
        return Data(bytes: ptr, count: count)
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else {
            throw WikiStoreError.sqlite(code: rc, message: Self.message(db))
        }
    }

    static func message(_ db: OpaquePointer?) -> String {
        guard let db, let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }
}
