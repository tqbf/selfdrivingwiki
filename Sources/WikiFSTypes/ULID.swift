import Foundation

/// Dependency-free ULID generator.
///
/// Specification: https://github.com/ulid/spec
///
/// A ULID is a 128-bit value: a 48-bit big-endian millisecond Unix timestamp
/// followed by 80 bits, rendered as 26 Crockford base32 characters. Because the
/// timestamp is the high-order component and base32 is encoded most-significant-
/// first, ULIDs sort **lexicographically in creation order** — the property we
/// lean on for `PageID` ordering and future date views.
///
/// Monotonic within the same millisecond per the spec: the random component is
/// seeded randomly for the first ULID of a new timestamp, then incremented for
/// subsequent ULIDs in that same millisecond. This guarantees lexicographic
/// ordering across any number of generations.
public enum ULID {
    /// Crockford base32 alphabet (no I, L, O, U to avoid ambiguity).
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The Crockford base32 character set (uppercase only — the confusable
    /// digits `I`/`L`/`O`/`U` are NOT members). Used by `isCanonicalULID` so a
    /// single source of truth governs what a canonical link target looks like.
    /// Uppercase-only because `ULID.generate` always emits uppercase: a lowercase
    /// string is never a legitimately canonical id, and treating it as one would
    /// skip the canonicalizer (idempotency fast-path) yet miss every case-
    /// sensitive id lookup (`getPage(id:)`, `pageIDToName[id]`), rendering it as
    /// a ghost. Restricting to uppercase makes a lowercase ULID resolve by name
    /// (which fails) → ghost, the safest behavior for hand-edited content.
    public static let allowedCharacters: CharacterSet = {
        var set = CharacterSet()
        for ch in alphabet { set.insert(charactersIn: String(ch)) }
        return set
    }()

    /// A ULID generator with its own independent monotonic state.
    ///
    /// Monotonicity (same-millisecond incrementing of the random component) is
    /// per-generator, matching the ULID spec. Callers that need an isolated
    /// sequence — notably tests — own a `Generator` instance instead of the
    /// process-global `ULID.generate()`, so concurrent generators running at
    /// other timestamps can't perturb their ordering. `@unchecked Sendable` is
    /// correct because `lock` serializes all access to the mutable state.
    // `lock` serializes all access to `lastTimestamp`/`lastRandom`.
    // swiftlint:disable:next unchecked_sendable
    public final class Generator: @unchecked Sendable {
        private let lock = NSLock()
        private var lastTimestamp: UInt64 = 0
        private var lastRandom: [UInt8] = [UInt8](repeating: 0, count: 10)

        public init() {}

        /// Generate a new 26-character ULID at `timestamp`. Guaranteed
        /// lexicographically sortable: within the same millisecond the random
        /// component increments monotonically instead of re-randomizing.
        /// - Parameter timestamp: the moment to encode; defaults to now.
        public func next(
            at timestamp: Date = Date(),
            using generator: inout some RandomNumberGenerator
        ) -> String {
            let ms = UInt64(max(0, timestamp.timeIntervalSince1970) * 1000)

            let random: [UInt8] = lock.withLock {
                if ms == lastTimestamp {
                    // Same ms: increment the random component for monotonicity.
                    lastRandom = ULID.incrementBytes(lastRandom)
                } else {
                    // New ms: fresh random bytes.
                    lastTimestamp = ms
                    for i in 0..<10 {
                        lastRandom[i] = UInt8.random(in: 0...255, using: &generator)
                    }
                }
                return lastRandom
            }

            var b = [UInt8](repeating: 0, count: 16)
            for i in 0..<6 {
                b[i] = UInt8((ms >> (8 * (5 - i))) & 0xFF)
            }
            for i in 0..<10 {
                b[6 + i] = random[i]
            }
            return ULID.encodeBase32(b)
        }

        /// Convenience overload using the system RNG.
        public func next(at timestamp: Date = Date()) -> String {
            var rng = SystemRandomNumberGenerator()
            return next(at: timestamp, using: &rng)
        }
    }

    /// Process-wide monotonic generator backing the static `generate` API. A
    /// single shared instance means the same single-lock serialization as the
    /// previous static implementation, so every existing `ULID.generate()`
    /// caller sees identical ordering behavior.
    private static let shared = Generator()

    /// Generate a new 26-character ULID string. Delegates to the shared
    /// generator, preserving the original single-lock monotonicity for every
    /// caller.
    /// - Parameter timestamp: the moment to encode; defaults to now. Exposed so
    ///   tests can pin increasing timestamps and assert lexicographic ordering.
    public static func generate(
        at timestamp: Date = Date(),
        using generator: inout some RandomNumberGenerator
    ) -> String {
        shared.next(at: timestamp, using: &generator)
    }

    /// Increment a 10-byte big-endian integer in place, returning the new array.
    /// Wraps around to 0 on overflow (vanishingly unlikely with 80 bits).
    private static func incrementBytes(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        for i in (0..<10).reversed() {
            if b[i] < 0xFF {
                b[i] &+= 1
                return b
            }
            b[i] = 0
        }
        return b  // overflow: wraps to all zeros
    }

    /// Convenience overload using the system RNG.
    public static func generate(at timestamp: Date = Date()) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(at: timestamp, using: &rng)
    }

    /// Encode 16 bytes (128 bits) as 26 Crockford base32 characters. We treat
    /// the bytes as one big integer and peel off 5 bits at a time from the top.
    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        // 128 bits -> 26 chars (130 bits, top 2 bits always 0).
        var bits = 0
        var value = 0
        var out = [Character]()
        out.reserveCapacity(26)

        // Prepend two zero bits so the total is a multiple of 5 (130 bits).
        // Process bytes MSB-first, emitting a char whenever >= 5 bits buffered.
        value = 0
        bits = 2  // two leading pad bits
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = (value >> bits) & 0x1F
                out.append(alphabet[index])
            }
        }
        return String(out)
    }
}
