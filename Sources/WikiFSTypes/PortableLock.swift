import Foundation
#if canImport(os)
import os
#endif

/// A portable mutual-exclusion lock with a `withLock` closure API mirroring
/// `OSAllocatedUnfairLock` from the macOS `os` module.
///
/// On macOS (`canImport(os)`), this delegates directly to
/// `OSAllocatedUnfairLock` — the low-overhead, unfair lock used throughout the
/// codebase for `Sendable` synchronized state. On Linux (and other platforms
/// without the `os` module), it falls back to an `NSLock`-based wrapper with
/// the same API surface so portable targets compile and run identically.
///
/// The fallback is for CI/test portability only — the app itself runs on macOS
/// and always uses `OSAllocatedUnfairLock`. The `NSLock` fallback is slightly
/// heavier (heap-allocated, Obj-C interop) but functionally equivalent for
/// test purposes.
public struct PortableLock<State: Sendable>: Sendable {
    #if canImport(os)
    private let storage: OSAllocatedUnfairLock<State>
    #else
    private let storage: NSLockBox<State>
    #endif

    public init(initialState: State) {
        #if canImport(os)
        storage = OSAllocatedUnfairLock(initialState: initialState)
        #else
        storage = NSLockBox(wrapped: initialState)
        #endif
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        #if canImport(os)
        return try storage.withLockUnchecked(body)
        #else
        return try storage.withLock(body)
        #endif
    }
}

#if !canImport(os)
/// A simple `NSLock`-backed mutable box that mimics
/// `OSAllocatedUnfairLock.withLock`. `NSLock` is available in
/// swift-corelibs-foundation on Linux.
final class NSLockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(wrapped: Value) {
        self.value = wrapped
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
#endif
