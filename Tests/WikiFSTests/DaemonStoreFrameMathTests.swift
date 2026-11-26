#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract

// Frame math contract for the store family (plan 2a): every assertion here
// measures the FINAL OUTER encoded envelope — the bytes the framed transport
// carries — never the inner DTO size. A 1 MiB raw chunk crosses THREE base64
// layers in the store family's envelope stack (chunk `Data` inside the DTO
// JSON, the DTO JSON inside the store reply's `result` `Data`, the store
// reply JSON inside the domain envelope's `payload` `Data`) and lands ≈
// 2.37 MiB — under `SearchSocketWire.maxFrameSize` with headroom. Boundary
// behavior: just-below/at the cap is accepted; just-above raises the typed
// ``DaemonStoreFrameError``.

@Suite("Daemon store frame sizing", .timeLimit(.minutes(2)))
struct DaemonStoreFrameMathTests {

    /// Builds a `.store` reply envelope carrying one chunk request DTO whose
    /// `bytes` field holds `rawChunkByteCount` raw bytes, and returns the
    /// final outer encoded byte count (the real frame payload size).
    private func outerEncodedByteCount(
        rawChunkByteCount: Int,
        requestID: String = "frame-math-probe"
    ) throws -> Int {
        let chunk = DaemonPayloadChunkRequest(
            uploadID: "01HX8Q4K7M3N2P5R8T9V0WXY6Z",
            orderIndex: 0,
            bytes: Data(repeating: 0xA5, count: rawChunkByteCount),
            runningSHA256Hex: String(repeating: "a", count: 64))
        let storeReply = DaemonStoreReply(
            result: try JSONEncoder().encode(chunk), error: nil)
        let envelope = try DaemonDomainReply(
            requestID: requestID,
            family: .store,
            operation: DaemonStoreOperation.payloadChunk.rawValue,
            payload: DaemonStoreWire.encode(storeReply))
        return try DaemonDomainWire.encode(envelope).count
    }

    @Test("a full 1 MiB raw chunk stays under the 4 MiB frame cap")
    func oneMebibyteChunkStaysUnderCap() throws {
        let outer = try outerEncodedByteCount(
            rawChunkByteCount: DaemonStoreLimits.maxChunkBytes)
        let cap = Int(DaemonStoreFrameSizing.maxFrameSize)

        // Under the cap with >1.5 MiB headroom.
        #expect(outer < cap)
        // Pin the measured three-layer math: three 4/3 inflations of the
        // raw chunk plus fixed overhead ≈ 2.37 MiB (the design record's
        // ≈1.83 MiB figure counted only the two layers of a single-nested
        // payload — the store reply envelope adds the third).
        #expect(outer > 2_300_000)
        #expect(outer < 2_600_000)
        // The shared conservative bound must cover the real encoded size —
        // preflight acceptance never surprises at encode time.
        let bound = DaemonStoreFrameSizing.outerEncodedBound(
            rawChunkByteCount: DaemonStoreLimits.maxChunkBytes)
        #expect(bound >= outer)
        #expect(bound <= cap)
        #expect(DaemonStoreFrameSizing.chunkFitsFrameCap(
            rawChunkByteCount: DaemonStoreLimits.maxChunkBytes))
    }

    @Test("the conservative bound covers real encoded sizes across chunk sizes")
    func boundCoversRealSizes() throws {
        for raw in [0, 1, 1_000, 512 * 1_024, DaemonStoreLimits.maxChunkBytes] {
            let outer = try outerEncodedByteCount(rawChunkByteCount: raw)
            let bound = DaemonStoreFrameSizing.outerEncodedBound(
                rawChunkByteCount: raw)
            #expect(bound >= outer,
                    "bound \(bound) must cover real \(outer) for raw \(raw)")
        }
    }

    @Test(
        "chunk byte count validation raises the typed chunk error",
        arguments: [
            DaemonStoreLimits.maxChunkBytes + 1,
            5 * 1_048_576,
        ])
    func oversizedChunkIsTypedRejection(raw: Int) {
        #expect(throws: DaemonStoreFrameError.chunkTooLarge(
            rawBytes: raw, limit: DaemonStoreLimits.maxChunkBytes)) {
            try DaemonStoreFrameSizing.validateChunkByteCount(raw)
        }
        // The limit itself is legal.
        #expect(throws: Never.self) {
            try DaemonStoreFrameSizing.validateChunkByteCount(
                DaemonStoreLimits.maxChunkBytes)
        }
    }

    @Test(
        "just-below/at the cap is accepted; just-above raises the typed frame error")
    func capBoundariesAreTyped() throws {
        let cap = Int(DaemonStoreFrameSizing.maxFrameSize)

        // Far above the cap: a 3 MiB raw chunk's three 4/3 inflations land
        // well past 4 MiB.
        #expect(try outerEncodedByteCount(rawChunkByteCount: 3 * 1_048_576) > cap)

        // Binary search the flip point on the REAL outer encoded size: the
        // largest raw chunk size whose final envelope still fits.
        var accepted = 0
        var rejected = 3 * 1_048_576
        while rejected - accepted > 1 {
            let mid = accepted + (rejected - accepted) / 2
            if try outerEncodedByteCount(
                rawChunkByteCount: mid, requestID: "cap-boundary") <= cap {
                accepted = mid
            } else {
                rejected = mid
            }
        }

        // Just below / at the cap: the validated encode seam accepts it,
        // measuring the same outer size as a raw encode.
        let belowOrAt = try outerEncodedByteCount(
            rawChunkByteCount: accepted, requestID: "cap-boundary")
        #expect(belowOrAt <= cap)
        let envelope = try DaemonDomainReply(
            requestID: "cap-boundary",
            family: .store,
            operation: DaemonStoreOperation.payloadChunk.rawValue,
            payload: DaemonStoreWire.encode(DaemonStoreReply(
                result: try JSONEncoder().encode(DaemonPayloadChunkRequest(
                    uploadID: "01HX8Q4K7M3N2P5R8T9V0WXY6Z",
                    orderIndex: 0,
                    bytes: Data(repeating: 0x5A, count: accepted),
                    runningSHA256Hex: String(repeating: "b", count: 64))),
                error: nil)))
        let validated = try DaemonStoreFrameSizing.encodeValidatedReply(envelope)
        #expect(validated.count == belowOrAt)

        // Just above the cap: the first raw size that flips the outer size
        // over raises the typed error naming the real size and the limit.
        let above = try outerEncodedByteCount(
            rawChunkByteCount: rejected, requestID: "cap-boundary")
        #expect(above > cap)
        let oversized = try DaemonDomainReply(
            requestID: "cap-boundary",
            family: .store,
            operation: DaemonStoreOperation.payloadChunk.rawValue,
            payload: DaemonStoreWire.encode(DaemonStoreReply(
                result: try JSONEncoder().encode(DaemonPayloadChunkRequest(
                    uploadID: "01HX8Q4K7M3N2P5R8T9V0WXY6Z",
                    orderIndex: 0,
                    bytes: Data(repeating: 0x5A, count: rejected),
                    runningSHA256Hex: String(repeating: "c", count: 64))),
                error: nil)))
        #expect(throws: DaemonStoreFrameError.exceedsMaxFrameSize(
            outerEncodedBytes: above, limit: DaemonStoreFrameSizing.maxFrameSize)) {
            try DaemonStoreFrameSizing.encodeValidatedReply(oversized)
        }
    }

    @Test("validated request seam measures the same outer size as raw encode")
    func validatedRequestMatchesRawEncode() throws {
        let storeRequest = DaemonStoreRequest(
            wikiID: "01JSTOREWIKI0000000000000A",
            operation: DaemonStoreOperation.getPage.rawValue,
            payload: Data("{\"pageID\":\"01JPAGE0000000000000000AA\"}".utf8))
        let envelope = DaemonDomainRequest(
            requestID: "req-1",
            family: .store,
            operation: DaemonStoreOperation.getPage.rawValue,
            payload: try DaemonStoreWire.encode(storeRequest))
        let validated = try DaemonStoreFrameSizing.encodeValidatedRequest(envelope)
        let raw = try DaemonDomainWire.encode(envelope)
        #expect(validated.count == raw.count)
    }

    @Test("the .store family string round-trips through the domain envelope")
    func storeFamilyRoundTrip() throws {
        let envelope = DaemonDomainRequest(
            requestID: "family-probe",
            family: .store,
            operation: DaemonStoreOperation.sessionBootstrap.rawValue)
        let data = try DaemonDomainWire.encode(envelope)
        let decoded = try DaemonDomainWire.decodeRequest(data)
        #expect(decoded.family == .store)
        #expect(decoded.family.rawValue == "store")
        #expect(decoded.operation == DaemonStoreOperation.sessionBootstrap.rawValue)
    }
}
#endif
