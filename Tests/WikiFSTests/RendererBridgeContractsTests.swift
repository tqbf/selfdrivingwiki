import Foundation
import Testing
@testable import WikiFSCore

struct RendererBridgeContractsTests {
    @Test("input read accepts one fresh, bounded request for its capability")
    func acceptsFreshBoundedRequest() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let request = RendererBridgeRequest(
            id: .init(rawValue: "request-1"),
            method: .inputRead,
            capability: capability,
            input: .source(versionID: .init(rawValue: "version-1"))
        )
        let envelope = try RendererBridgeEnvelope.encode(request)
        var authorizer = RendererBridgeAuthorizer(capability: capability)

        #expect(try authorizer.authorize(envelope: envelope, sessionIsReady: true) == request)
    }

    @Test("authorizer rejects malformed, oversized, duplicate, and unavailable session requests")
    func rejectsInvalidRequests() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let request = RendererBridgeRequest(id: .init(rawValue: "request-1"), method: .inputRead, capability: capability, input: .markdown(versionID: .init(rawValue: "markdown-1")))
        var authorizer = RendererBridgeAuthorizer(capability: capability)
        let valid = try RendererBridgeEnvelope.encode(request)
        #expect(throws: RendererBridgeAuthorizationError.sessionNotReady) { try authorizer.authorize(envelope: valid, sessionIsReady: false) }
        #expect(try authorizer.authorize(envelope: valid, sessionIsReady: true) == request)
        #expect(throws: RendererBridgeAuthorizationError.duplicateRequestID) { try authorizer.authorize(envelope: valid, sessionIsReady: true) }
        #expect(throws: RendererBridgeAuthorizationError.malformedEnvelope) { try authorizer.authorize(envelope: Data("no".utf8), sessionIsReady: true) }
        #expect(throws: RendererBridgeAuthorizationError.oversizedEnvelope) { try authorizer.authorize(envelope: Data(repeating: 0, count: WikiAppWebViewPolicy.maximumBridgeMessageByteCount + 1), sessionIsReady: true) }
    }

    @Test("a wrong capability does not consume the request ID")
    func rejectsWrongCapabilityWithoutBurningRequestID() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let requestID = RendererBridgeRequestID(rawValue: "request-1")
        let mismatchedRequest = RendererBridgeRequest(
            id: requestID,
            method: .inputRead,
            capability: .init(rawValue: "wrong-capability"),
            input: .source(versionID: .init(rawValue: "version-1"))
        )
        let validRequest = RendererBridgeRequest(
            id: requestID,
            method: .inputRead,
            capability: capability,
            input: .source(versionID: .init(rawValue: "version-1"))
        )
        var authorizer = RendererBridgeAuthorizer(capability: capability)

        #expect(throws: RendererBridgeAuthorizationError.capabilityMismatch) {
            try authorizer.authorize(
                envelope: try RendererBridgeEnvelope.encode(mismatchedRequest),
                sessionIsReady: true
            )
        }
        #expect(
            try authorizer.authorize(
                envelope: try RendererBridgeEnvelope.encode(validRequest),
                sessionIsReady: true
            ) == validRequest
        )
    }

    @Test("authorizer binds a request to its session window main frame and pinned input")
    func bindsSessionWindowFrameAndInput() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let sessionID = RendererSessionID(rawValue: UUID())
        let windowID = UUID()
        let mainFrameID = UUID()
        let input = RendererBridgeInput.source(versionID: .init(rawValue: "version-1"))
        let request = RendererBridgeRequest(id: .init(rawValue: "request-1"), method: .inputRead, capability: capability, input: input)
        let envelope = try RendererBridgeEnvelope.encode(request)
        let context = RendererBridgeAuthorizationContext(sessionID: sessionID, windowID: windowID, frameID: mainFrameID, mainFrameID: mainFrameID)
        var authorizer = RendererBridgeAuthorizer(capability: capability, sessionID: sessionID, windowID: windowID, authorizedInput: input)

        #expect(try authorizer.authorize(envelope: envelope, context: context, sessionIsReady: true, sessionIsClosed: false) == request)

        var wrongWindow = RendererBridgeAuthorizer(capability: capability, sessionID: sessionID, windowID: windowID, authorizedInput: input)
        let otherWindow = RendererBridgeAuthorizationContext(sessionID: sessionID, windowID: UUID(), frameID: mainFrameID, mainFrameID: mainFrameID)
        #expect(throws: RendererBridgeAuthorizationError.wrongWindow) { try wrongWindow.authorize(envelope: envelope, context: otherWindow, sessionIsReady: true, sessionIsClosed: false) }

        var nonMainFrame = RendererBridgeAuthorizer(capability: capability, sessionID: sessionID, windowID: windowID, authorizedInput: input)
        let childFrame = RendererBridgeAuthorizationContext(sessionID: sessionID, windowID: windowID, frameID: UUID(), mainFrameID: mainFrameID)
        #expect(throws: RendererBridgeAuthorizationError.nonMainFrame) { try nonMainFrame.authorize(envelope: envelope, context: childFrame, sessionIsReady: true, sessionIsClosed: false) }
    }

    @Test("inline artifact requests remain typed and replay-safe")
    func inlineArtifactRequestAuthorization() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let pageID = PageID(rawValue: "01HTESTPAGE000000000000001")
        let pageVersionID = PageVersionID(rawValue: "01HTESTPV00000000000000001")
        let bytes = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let blockID = try MarkdownBlockID(
            pageID: pageID,
            pageVersionID: pageVersionID,
            parserOrdinal: 0,
            digest: RendererSHA256.digest(bytes))
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: blockID,
            fenceKind: .jsoncanvas,
            mimeType: .init(rawValue: "application/json")!,
            bytes: bytes)
        let input = RendererBridgeInput.inlineArtifact(artifact)
        let request = RendererBridgeRequest(id: .init(rawValue: "request-inline"), method: .inputRead, capability: capability, input: input)
        let envelope = try RendererBridgeEnvelope.encode(request)
        var authorizer = RendererBridgeAuthorizer(capability: capability)

        #expect(try authorizer.authorize(envelope: envelope, sessionIsReady: true) == request)
        #expect(throws: RendererBridgeAuthorizationError.duplicateRequestID) {
            try authorizer.authorize(envelope: envelope, sessionIsReady: true)
        }
    }

    @Test("request identifiers are bounded before replay retention")
    func requestIdentifiersAreBoundedBeforeReplayRetention() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let input = RendererBridgeInput.source(versionID: .init(rawValue: "version-1"))

        let emptyID = RendererBridgeRequest(
            id: .init(rawValue: ""), method: .inputRead, capability: capability, input: input
        )
        var emptyAuthorizer = RendererBridgeAuthorizer(capability: capability)
        #expect(throws: RendererBridgeAuthorizationError.invalidRequestID) {
            try emptyAuthorizer.authorize(envelope: RendererBridgeEnvelope.encode(emptyID), sessionIsReady: true)
        }

        let oversizedID = RendererBridgeRequest(
            id: .init(rawValue: String(repeating: "x", count: WikiAppWebViewPolicy.maximumBridgeRequestIDByteCount + 1)),
            method: .inputRead,
            capability: capability,
            input: input
        )
        var oversizedAuthorizer = RendererBridgeAuthorizer(capability: capability)
        #expect(throws: RendererBridgeAuthorizationError.invalidRequestID) {
            try oversizedAuthorizer.authorize(envelope: RendererBridgeEnvelope.encode(oversizedID), sessionIsReady: true)
        }
    }

    @Test("replay retention has a deterministic bound")
    func replayRetentionHasDeterministicBound() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let input = RendererBridgeInput.source(versionID: .init(rawValue: "version-1"))
        var authorizer = RendererBridgeAuthorizer(capability: capability)

        for index in 0..<WikiAppWebViewPolicy.maximumRetainedBridgeRequestIDs {
            let request = RendererBridgeRequest(
                id: .init(rawValue: "request-\(index)"),
                method: .inputRead,
                capability: capability,
                input: input
            )
            _ = try authorizer.authorize(
                envelope: RendererBridgeEnvelope.encode(request),
                sessionIsReady: true
            )
        }

        let overflow = RendererBridgeRequest(
            id: .init(rawValue: "overflow"),
            method: .inputRead,
            capability: capability,
            input: input
        )
        #expect(throws: RendererBridgeAuthorizationError.replayCapacityExceeded) {
            try authorizer.authorize(envelope: RendererBridgeEnvelope.encode(overflow), sessionIsReady: true)
        }
    }
}
