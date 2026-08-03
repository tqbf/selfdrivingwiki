// Portable SHA-256 wrapper.
//
// On macOS, `CryptoKit` (system framework) provides `SHA256.hash(data:)`.
// On Linux, `swift-crypto` (already a transitive dependency via GRDB)
// provides the identical API under the `Crypto` module.
//
// This shim exposes a single `portableSHA256(_:)` function so callers don't
// need to worry about which module resolved `SHA256`.

import Foundation

#if canImport(CryptoKit)
import CryptoKit

func portableSHA256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
#elseif canImport(Crypto)
import Crypto

func portableSHA256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
#endif
