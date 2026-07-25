import Foundation
import Testing
import WikiFSTypes

/// Tests for `ULID` monotonicity, timestamp encoding, and carry propagation.
///
/// These tests kill the surviving mutation-testing mutants from issue #898:
/// the `* 1000` → `/ 1000` timestamp-encoding swap, the `ms == lastTimestamp`
/// conditional mutations, and the `b[i] < 0xFF` relational mutation in
/// `incrementBytes`.
///
/// `ULID.generate(at:using:)` takes an injected `Date` and
/// `inout some RandomNumberGenerator` specifically so this is testable
/// without sleeping.
///
/// `.serialized` for stability: the monotonicity tests use isolated
/// `ULID.Generator` instances, but keeping the suite serialized avoids any
/// residual timing sensitivity across the timestamp-encoding round-trip checks.
@Suite(.serialized)
struct ULIDTests {

    // MARK: - Helpers

    /// Deterministic LCG for reproducible random-byte predictions.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Decode a 26-char Crockford base32 ULID back to its 16 raw bytes.
    /// Mirrors `ULID.encodeBase32` in reverse.
    ///
    /// The bit stream is `[2 pad zeros][128 data bits]` = 130 bits = 26 × 5.
    /// The first char's top 2 bits are always-zero pad; we discard them so
    /// the 128 data bits align to byte boundaries.
    private func decodeToBytes(_ ulid: String) -> [UInt8] {
        let alpha = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let chars = Array(ulid)

        var bits = 0
        var value = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)

        for (i, c) in chars.enumerated() {
            let idx = alpha.firstIndex(of: c) ?? 0
            value = (value << 5) | idx
            bits += 5
            if i == 0 {
                // Discard the 2 leading pad bits — keep only the bottom 3.
                value &= 0x07
                bits = 3
            }
            while bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return bytes
    }

    /// Extract the 48-bit millisecond timestamp from a ULID (first 6 bytes).
    private func decodeTimestamp(_ ulid: String) -> UInt64 {
        let bytes = decodeToBytes(ulid)
        var ts: UInt64 = 0
        for i in 0..<6 { ts = (ts << 8) | UInt64(bytes[i]) }
        return ts
    }

    /// Extract the 80-bit random component from a ULID (last 10 bytes).
    private func decodeRandom(_ ulid: String) -> [UInt8] {
        let bytes = decodeToBytes(ulid)
        return Array(bytes[6..<16])
    }

    // MARK: - Timestamp encoding (kills `* 1000` → `/ 1000` at ULID.swift:51)

    @Test func timestampEncodingRoundTripsKnownEpoch() {
        // 2024-01-15 12:00:00 UTC = 1_705_323_200 s → 1_705_323_200_000 ms
        let date = Date(timeIntervalSince1970: 1_705_323_200)
        let ulid = ULID.generate(at: date)
        let decoded = decodeTimestamp(ulid)
        #expect(decoded == 1_705_323_200_000)
    }

    @Test func timestampEncodingRoundTripsEpochZero() {
        let ulid = ULID.generate(at: Date(timeIntervalSince1970: 0))
        #expect(decodeTimestamp(ulid) == 0)
    }

    @Test func timestampEncodingRoundTripsFutureDate() {
        // A large value that exercises the high bytes of the 48-bit prefix.
        let ms: UInt64 = 9_999_999_999_999  // ~2286 AD
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let ulid = ULID.generate(at: date)
        #expect(decodeTimestamp(ulid) == ms)
    }

    // MARK: - Same-millisecond monotonicity
    // Kills `ms == lastTimestamp` → `!=` (54:19) and negate (54:16).

    @Test func sameMillisecondGeneratesStrictlyIncreasingULIDs() {
        // A private generator isolates our monotonic sequence from concurrent
        // `ULID.generate()` calls (now-time) in other suites, which would reset
        // the shared global state mid-loop and break ordering.
        let gen = ULID.Generator()
        let date = Date(timeIntervalSince1970: 1_111_111)
        var rng = SeededRNG(42)
        var ulids: [String] = []
        for _ in 0..<20 {
            ulids.append(gen.next(at: date, using: &rng))
        }
        for i in 1..<ulids.count {
            #expect(ulids[i] > ulids[i - 1])
        }
    }

    @Test func newTimestampSeedsFreshRandomFromGenerator() {
        // A fresh generator starts with lastTimestamp == 0, so the first call at
        // any real timestamp deterministically takes the fresh-random branch,
        // consuming 10 bytes from `generator`. If the conditional is mutated
        // (`==` → `!=` or negated), the increment branch runs instead and the
        // generator is never consulted — the random component won't match.
        let gen = ULID.Generator()
        let date = Date(timeIntervalSince1970: 2_222_222)
        var rng = SeededRNG(99)
        let ulid = gen.next(at: date, using: &rng)

        // Predict the same 10 bytes from an identical seed.
        var predictRng = SeededRNG(99)
        var predicted = [UInt8](repeating: 0, count: 10)
        for i in 0..<10 {
            predicted[i] = UInt8.random(in: 0...255, using: &predictRng)
        }
        #expect(decodeRandom(ulid) == predicted)
    }

    // MARK: - Carry propagation (kills `b[i] < 0xFF` at ULID.swift:82)

    @Test func carryAcrossByteBoundaryPreservesOrdering() {
        // A private generator isolates the sequence from concurrent global
        // `ULID.generate()` calls (see above). Generate enough same-ms ULIDs to
        // cross at least one 0xFF→0x00 boundary in the random component (512
        // guarantees two full cycles of the least-significant byte). If
        // `b[i] < 0xFF` is mutated to `<=` or another relational, the carry is
        // lost and the sequence breaks monotonicity at that boundary.
        let gen = ULID.Generator()
        let date = Date(timeIntervalSince1970: 3_333_333)
        var rng = SeededRNG(7)
        var prev = gen.next(at: date, using: &rng)
        for _ in 0..<512 {
            let next = gen.next(at: date, using: &rng)
            #expect(next > prev)
            prev = next
        }
    }

    // MARK: - Cross-millisecond ordering

    @Test func laterTimestampSortsAfterEarlierTimestamp() {
        let earlier = ULID.generate(at: Date(timeIntervalSince1970: 4_000_000))
        let later = ULID.generate(at: Date(timeIntervalSince1970: 5_000_000))
        #expect(later > earlier)
    }

    // MARK: - Format invariants

    @Test func generatedULIDIs26CharsAndUppercase() {
        let ulid = ULID.generate()
        #expect(ulid.count == 26)
        #expect(ulid.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    @Test func generatedULIDUsesOnlyCrockfordAlphabet() {
        let ulid = ULID.generate()
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        #expect(Set(ulid).isSubset(of: allowed))
    }
}
