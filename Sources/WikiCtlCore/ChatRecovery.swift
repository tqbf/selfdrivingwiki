import Foundation
import WikiFSCore

// pattern: Functional Core

/// Recovery helpers for a persisted assistant message whose durable text does
/// not match the retained ACP debug trace. The parser is deliberately small:
/// it consumes only the JSONL wire updates written by `DebugRunLogger` and
/// never guesses from rendered markdown or compatibility rows.
public enum ChatRecovery {

    public struct RecoveredResponse: Equatable, Sendable {
        public let text: String
        public let wireMessageID: String?

        public init(text: String, wireMessageID: String?) {
            self.text = text
            self.wireMessageID = wireMessageID
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case malformedLine(Int)
        case malformedUpdate(Int)
        case noFinalAnswer
        case emptyFinalAnswer
        case ambiguousMessageIDs([String])

        public var description: String {
            switch self {
            case .malformedLine(let line):
                return "debug updates line \(line) is not valid JSON"
            case .malformedUpdate(let line):
                return "debug updates line \(line) has an incomplete agent message chunk"
            case .noFinalAnswer:
                return "debug updates contain no final assistant message chunks"
            case .emptyFinalAnswer:
                return "debug updates contain an empty final assistant response"
            case .ambiguousMessageIDs(let ids):
                return "debug updates contain multiple final assistant message IDs: \(ids.joined(separator: ", "))"
            }
        }
    }

    /// Reconstruct the final assistant response in wire-file order.
    ///
    /// Non-message updates and reasoning chunks are ignored. If a provider
    /// omits the phase metadata, its `agent_message_chunk` is still eligible;
    /// this keeps the recovery path compatible with older debug artifacts.
    public static func recover(from data: Data) throws -> RecoveredResponse {
        var chunks: [String] = []
        var messageIDs = Set<String>()
        var messageIDByMarker: [String: String?] = [:]
        let decoder = JSONDecoder()

        var lineNumber = 0
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lineNumber += 1
            let line = Data(rawLine)
            let envelope: WireEnvelope
            do {
                envelope = try decoder.decode(WireEnvelope.self, from: line)
            } catch {
                throw Failure.malformedLine(lineNumber)
            }

            guard let update = envelope.params?.update,
                  update.sessionUpdate == "agent_message_chunk" else { continue }
            let messageEnvelope: WireMessageEnvelope
            do {
                messageEnvelope = try decoder.decode(WireMessageEnvelope.self, from: line)
            } catch {
                throw Failure.malformedUpdate(lineNumber)
            }
            guard let message = messageEnvelope.params?.update else {
                throw Failure.malformedUpdate(lineNumber)
            }
            if let phase = message.meta?.codex?.phase, phase != "final_answer" { continue }
            guard let text = message.content?.text else {
                throw Failure.malformedUpdate(lineNumber)
            }

            let marker = message.messageID ?? "<missing-message-id>"
            messageIDs.insert(marker)
            messageIDByMarker[marker] = message.messageID
            chunks.append(text)
        }

        guard !chunks.isEmpty else { throw Failure.noFinalAnswer }
        guard messageIDs.count == 1 else {
            throw Failure.ambiguousMessageIDs(messageIDs.sorted())
        }
        guard let marker = messageIDs.first else {
            throw Failure.noFinalAnswer
        }
        let text = chunks.joined()
        guard !text.isEmpty else { throw Failure.emptyFinalAnswer }
        return RecoveredResponse(text: text, wireMessageID: messageIDByMarker[marker] ?? nil)
    }

    private struct WireEnvelope: Decodable {
        let params: Parameters?

        struct Parameters: Decodable {
            let update: Update?
        }

        struct Update: Decodable {
            let sessionUpdate: String?
            enum CodingKeys: String, CodingKey { case sessionUpdate }
        }
    }

    private struct WireMessageEnvelope: Decodable {
        let params: Parameters?

        struct Parameters: Decodable {
            let update: Update?
        }

        struct Update: Decodable {
            let messageID: String?
            let content: Content?
            let meta: Meta?

            enum CodingKeys: String, CodingKey {
                case messageID = "messageId"
                case content
                case meta = "_meta"
            }
        }

        struct Content: Decodable {
            let text: String?
        }

        struct Meta: Decodable {
            let codex: Codex?
        }

        struct Codex: Decodable {
            let phase: String?
        }
    }
}
