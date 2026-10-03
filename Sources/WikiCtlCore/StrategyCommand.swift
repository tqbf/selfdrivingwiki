import Foundation
import WikiFSCore

/// The `wikictl strategy …` subcommands: read, save, and reset for the
/// per-wiki editorial strategy singleton (`wiki_strategy`, the one row).
///
/// `read` prints the committed state — the strategy document together with
/// its revision counter, or the **Default** strategy (absence, or a reset
/// tombstone) with the revision the next save must expect. `save` and `reset`
/// are compare-and-swap writes through `WikiStore.saveWikiStrategy`: the
/// caller's `--expect-revision` must equal the committed row exactly —
/// `absent` when no strategy row has ever been written — and a mismatch
/// throws `WikiStrategyConflictError` before anything is written (`wikictl`
/// surfaces that as exit code 3).
///
/// Every content rule is inherited from the store seam, not restated here:
/// `WikiStrategy.validatedInput` enforces the named limits
/// (`nameCharacterLimit`, `instructionsUTF8ByteLimit`) visibly, and
/// whitespace-only instructions reset the wiki to the Default strategy —
/// `reset` is that path spelled as its own verb, with an empty document.
public enum StrategyCommand {

    /// What a command produced: text for stdout, an optional CAS-chaining
    /// line for stderr (text mode), and whether a CHANGED write committed
    /// (drives the per-wiki Darwin notification the app refreshes on).
    public struct Result: Equatable {
        public var output: String
        public var stderrOutput: String?
        public var didCommit: Bool

        public init(output: String, stderrOutput: String? = nil, didCommit: Bool) {
            self.output = output
            self.stderrOutput = stderrOutput
            self.didCommit = didCommit
        }
    }

    /// The compare-and-swap expectation exactly as the CLI spells it.
    /// `.absent` is the wiki where no strategy row has ever been written
    /// (the store's `nil` expectation — true absence, not a reset
    /// tombstone); `.revision(n)` pins the committed row revision, whether
    /// that row holds a live strategy or a Default tombstone.
    public enum ExpectedRevision: Equatable, Sendable {
        case absent
        case revision(WikiStrategyRevision)

        /// The value `WikiStore.saveWikiStrategy` expects.
        public var storeExpectation: WikiStrategyRevision? {
            switch self {
            case .absent: nil
            case .revision(let revision): revision
            }
        }
    }

    public enum Action: Equatable {
        case read(json: Bool)
        case save(name: String?, content: BodySource, expect: ExpectedRevision, json: Bool)
        case reset(expect: ExpectedRevision, json: Bool)
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    public static func run(_ action: Action, in store: WikiStore) throws -> Result {
        switch action {
        case .read(let json):
            return try read(in: store, json: json)
        case .save(let name, let content, let expect, let json):
            let instructions = try resolveBodySource(content)
            return try write(
                name: name ?? "", instructions: instructions,
                expect: expect, in: store, json: json)
        case .reset(let expect, let json):
            // The empty document is whitespace-only, which the write boundary
            // normalizes to a reset request: Default strategy, tombstone row,
            // revision stays monotonic. Same seam as the editor's reset.
            return try write(
                name: "", instructions: "",
                expect: expect, in: store, json: json)
        }
    }

    // MARK: - read

    private static func read(in store: WikiStore, json: Bool) throws -> Result {
        let state = try store.getWikiStrategyState()
        if json {
            return Result(output: try renderStateJSON(state), didCommit: false)
        }
        var lines: [String] = []
        if let revision = state.revision {
            lines.append("revision: \(revision.rawValue)")
        } else {
            lines.append("revision: absent")
        }
        if let strategy = state.strategy {
            lines.append("name: \(strategy.name.isEmpty ? "(unnamed)" : strategy.name)")
            lines.append("updated: \(strategy.updatedAt.formatted(.iso8601))")
            lines.append("---")
            lines.append(strategy.instructions)
        } else {
            lines.append("strategy: Default (no custom strategy)")
        }
        return Result(output: lines.joined(separator: "\n"), didCommit: false)
    }

    /// One JSON object describing the committed state. `revision` is `null`
    /// only for the never-written row (the `--expect-revision absent` case);
    /// a Default wiki that was reset keeps its tombstone revision, and
    /// `default` distinguishes it from a live strategy. Nil fields encode as
    /// explicit `null` (custom `encode`), not omitted keys — "no strategy row
    /// has ever been written" is data a caller must see, not a missing field.
    private static func renderStateJSON(_ state: WikiStrategyState) throws -> String {
        struct StateJSON: Codable {
            var revision: Int64?
            var `default`: Bool
            var name: String?
            var instructions: String?
            var updatedAt: String?

            private enum CodingKeys: String, CodingKey {
                case revision, `default`, name, instructions, updatedAt
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeNullingNil(revision, forKey: .revision)
                try container.encode(`default`, forKey: .default)
                try container.encodeNullingNil(name, forKey: .name)
                try container.encodeNullingNil(instructions, forKey: .instructions)
                try container.encodeNullingNil(updatedAt, forKey: .updatedAt)
            }
        }
        let payload = StateJSON(
            revision: state.revision?.rawValue,
            default: state.strategy == nil,
            name: state.strategy?.name,
            instructions: state.strategy?.instructions,
            updatedAt: state.strategy.map { $0.updatedAt.formatted(.iso8601) })
        return try jsonString(payload)
    }

    // MARK: - save / reset (one CAS write seam)

    private static func write(
        name: String,
        instructions: String,
        expect: ExpectedRevision,
        in store: WikiStore,
        json: Bool
    ) throws -> Result {
        let outcome = try store.saveWikiStrategy(
            name: name,
            instructions: instructions,
            expectedRevision: expect.storeExpectation)
        switch outcome {
        case .saved(let revision, let strategy):
            let didReset = strategy == nil
            let text: String
            if let strategy {
                let name = strategy.name.isEmpty ? "(unnamed)" : strategy.name
                text = "saved strategy — revision \(revision.rawValue) (name: \(name))"
            } else {
                text = "reset to Default strategy — revision \(revision.rawValue)"
            }
            if json {
                struct SavedJSON: Codable {
                    var outcome: String
                    var revision: Int64
                    var `default`: Bool
                }
                return Result(
                    output: try jsonString(SavedJSON(
                        outcome: "saved", revision: revision.rawValue, default: didReset)),
                    didCommit: true)
            }
            // Echo the next CAS token on stderr (text mode) so the next save
            // needs no extra read — the same contract as `page add`'s
            // head_version_id echo.
            return Result(
                output: text,
                stderrOutput: "next --expect-revision: \(revision.rawValue)",
                didCommit: true)
        case .unchanged:
            // Nothing was written; report the committed state so the caller
            // can compose its next expectation without a re-read. ONE
            // `getWikiStrategyState()` snapshot — two separate reads
            // (`wikiStrategyRevision()` then `getWikiStrategy()`) can straddle
            // a concurrent write and pair a stale revision with a fresh
            // strategy, the same incoherence the editor path avoids.
            let state = try store.getWikiStrategyState()
            if json {
                struct UnchangedJSON: Codable {
                    var outcome: String
                    var revision: Int64?
                    var `default`: Bool

                    private enum CodingKeys: String, CodingKey {
                        case outcome, revision, `default`
                    }

                    func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(outcome, forKey: .outcome)
                        try container.encodeNullingNil(revision, forKey: .revision)
                        try container.encode(`default`, forKey: .default)
                    }
                }
                return Result(
                    output: try jsonString(UnchangedJSON(
                        outcome: "unchanged",
                        revision: state.revision?.rawValue,
                        default: state.strategy == nil)),
                    didCommit: false)
            }
            let revisionText = state.revision.map { "revision \($0.rawValue)" } ?? "absent"
            let stateText = state.strategy == nil ? "already Default" : "strategy already matches"
            return Result(
                output: "unchanged — \(stateText) (\(revisionText))",
                didCommit: false)
        }
    }

    // MARK: - JSON helper

    /// Encode `nil` as an explicit JSON `null` rather than omitting the key
    /// (Codable's default `encodeIfPresent` behavior for synthesized structs).
    /// The strategy state uses absence as DATA — `revision: null` is the
    /// never-written row a caller must pass as `--expect-revision absent`.
    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullingNil<T: Encodable>(
        _ value: T?, forKey key: Key
    ) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
