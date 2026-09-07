import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Regression tests for scoped `--help` (#1224): top-level, family, leaf, and
/// nested-OKF-operation help all parse and exit without a wiki selection, and
/// the CLIReference spec that generates the help is the same table the parser
/// routes and validates with (so help cannot drift from behavior).
struct CLIHelpTests {

    private let noEnv: (String) -> String? = { _ in nil }

    // MARK: - Top-level

    @Test func topLevelHelpParsesWithoutWikiOrEnv() throws {
        let invocation = try ArgumentParser.parse(["--help"], env: noEnv)
        #expect(invocation.wikiSelector.isEmpty)
        #expect(invocation.command == .help(.topLevel))
    }

    @Test func topLevelShortHelpParses() throws {
        let invocation = try ArgumentParser.parse(["-h"], env: noEnv)
        #expect(invocation.command == .help(.topLevel))
    }

    @Test func helpBehindWikiFlagStillNeedsNoWiki() throws {
        let invocation = try ArgumentParser.parse(["--wiki", "W", "source", "--help"], env: noEnv)
        #expect(invocation.wikiSelector.isEmpty, "help short-circuits before wiki resolution")
        #expect(invocation.command == .help(.family("source")))
    }

    @Test func topLevelHelpListsEveryFamilyAndTopLevelCommand() {
        let text = ArgumentParser.usageText
        for family in CLIReference.families {
            #expect(text.contains(family.name), "top-level help mentions \(family.name)")
        }
        for leaf in CLIReference.topLevelCommands {
            #expect(text.contains(leaf.commandLine), "top-level help mentions \(leaf.name)")
        }
    }

    @Test func topLevelHelpKeepsLongstandingDocumentedFragments() {
        // The generated text must keep the fragments earlier help was trusted
        // for (pipe/heredoc body files, the selector grammars).
        let text = ArgumentParser.usageText
        #expect(text.contains("page add --title X"))
        #expect(text.contains("source add (--url URL"))
        #expect(text.contains("with a pipe or heredoc"))
        #expect(text.contains("exit status:"))
    }

    @Test func topLevelCommandHelpParses() throws {
        #expect(try ArgumentParser.parse(["version", "--help"], env: noEnv).command == .help(.topLevelCommand("version")))
        #expect(try ArgumentParser.parse(["--dump-config", "--help"], env: noEnv).command == .help(.topLevelCommand("--dump-config")))
    }

    // MARK: - Family level

    @Test func everyFamilyAcceptsHelpWithoutWiki() throws {
        for family in CLIReference.families {
            let invocation = try ArgumentParser.parse([family.name, "--help"], env: noEnv)
            #expect(invocation.command == .help(.family(family.name)))
        }
    }

    @Test func familyHelpDocumentsEveryLeaf() {
        for family in CLIReference.families {
            let text = CLIReference.helpText(for: .family(family.name))
            for leaf in family.leaves {
                #expect(
                    text.contains("\(family.name) \(leaf.name)"),
                    "\(family.name) --help lists \(leaf.name)")
                // Two-column tables wrap long summaries across lines, so only
                // the first chunk is guaranteed contiguous.
                #expect(
                    text.contains(String(leaf.summary.prefix(24))),
                    "\(family.name) --help summarizes \(leaf.name)")
            }
        }
    }

    @Test func familyHelpDocumentsFamilyOptions() {
        // `source cat --markdown` is real; the source family help must say so.
        let text = CLIReference.helpText(for: .family("source"))
        for option in CLIReference.options(forFamily: "source") {
            #expect(text.contains(option.name), "source --help documents \(option.name)")
        }
    }

    // MARK: - Leaf level

    @Test func everyLeafAcceptsHelpWithoutWiki() throws {
        for family in CLIReference.families {
            for leaf in family.leaves {
                let invocation = try ArgumentParser.parse(
                    [family.name, leaf.name, "--help"], env: noEnv)
                #expect(
                    invocation.command == .help(.leaf(family: family.name, subcommand: leaf.name, operation: nil)),
                    "\(family.name) \(leaf.name) --help")
            }
        }
    }

    @Test func leafHelpDocumentsItsOptions() {
        let add = CLIReference.helpText(for: .leaf(family: "source", subcommand: "add", operation: nil))
        #expect(add.contains("--url"))
        #expect(add.contains("--body-file"))
        #expect(add.contains("--name"))
        #expect(add.contains("--allow-duplicate"))
        #expect(add.contains("exit status:"))

        let get = CLIReference.helpText(for: .leaf(family: "page", subcommand: "get", operation: nil))
        #expect(get.contains("--workspace"))
        #expect(get.contains("exactly one"))

        let resolve = CLIReference.helpText(for: .leaf(family: "workspace", subcommand: "resolve", operation: nil))
        #expect(resolve.contains("--page"))
        #expect(resolve.contains("(required)"))
    }

    @Test func leafHelpIncludesExamplesWhereAuthored() {
        let add = CLIReference.helpText(for: .leaf(family: "source", subcommand: "add", operation: nil))
        #expect(add.contains("examples:"))
        #expect(add.contains("wikictl source add --url https://example.com/article"))
    }

    // MARK: - Nested OKF operations

    @Test func okfOperationAcceptsHelpWithoutWiki() throws {
        let invocation = try ArgumentParser.parse(["page", "okf", "verify", "--help"], env: noEnv)
        #expect(invocation.command == .help(.leaf(family: "page", subcommand: "okf", operation: "verify")))

        let source = try ArgumentParser.parse(["source", "okf", "inspect", "--help"], env: noEnv)
        #expect(source.command == .help(.leaf(family: "source", subcommand: "okf", operation: "inspect")))
    }

    @Test func okfLeafHelpListsAllOperations() throws {
        let invocation = try ArgumentParser.parse(["page", "okf", "--help"], env: noEnv)
        #expect(invocation.command == .help(.leaf(family: "page", subcommand: "okf", operation: nil)))
        let text = CLIReference.helpText(for: .leaf(family: "page", subcommand: "okf", operation: nil))
        for operation in CLIReference.okfOperations {
            #expect(text.contains(operation.name), "okf help lists \(operation.name)")
        }
    }

    @Test func okfOperationHelpDocumentsItsOptions() {
        let verify = CLIReference.helpText(for: .leaf(family: "page", subcommand: "okf", operation: "verify"))
        #expect(verify.contains("--basis"))
        #expect(verify.contains("--by"))
        // The evidence summary already says "repeatable"; the redundant
        // "(repeatable)" suffix is suppressed by design.
        #expect(verify.contains("repeatable"))
        let correct = CLIReference.helpText(for: .leaf(family: "source", subcommand: "okf", operation: "correct"))
        #expect(correct.contains("--verification"))
        #expect(correct.contains("(required)"))
    }

    // MARK: - Parser ↔ spec consistency (no drift)

    @Test func everyDocumentedLeafRoutesInTheParser() throws {
        // A leaf the spec documents but the parser's switch forgot would fail
        // here with an "unknown subcommand" usage error.
        for family in CLIReference.families {
            for leaf in family.leaves {
                do {
                    _ = try ArgumentParser.parse(["--wiki", "W", family.name, leaf.name], env: noEnv)
                } catch let failure as ArgumentParser.Failure {
                    #expect(
                        !failure.description.contains("unknown subcommand"),
                        "\(family.name) \(leaf.name) is documented but not routable: \(failure)")
                }
            }
        }
    }

    @Test func unknownSubcommandNamesTheKnownSet() throws {
        do {
            _ = try ArgumentParser.parse(["--wiki", "W", "source", "bogus"], env: noEnv)
            Issue.record("expected a usage error")
        } catch let failure as ArgumentParser.Failure {
            #expect(failure.description.contains("unknown subcommand"))
            #expect(failure.description.contains("set-active"))
            #expect(failure.description.contains("wikictl source --help"))
        }
    }

    @Test func unknownOptionIsALoudUsageError() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "source", "list", "--bogus"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "page", "add", "--title", "T", "--body-file", "-", "--bogus", "x"],
                env: noEnv)
        }
        // Value options are only accepted where their leaf documents them is
        // too strict for the shared family bag, but they must at least be in
        // the family's spec: --markdown belongs to the source family.
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "page", "list", "--markdown"], env: noEnv)
        }
    }

    @Test func helpDoesNotShadowMalformedCommands() {
        // Tokens past the command path are NOT help; normal parsing errors.
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "page", "okf", "bogus", "--help"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "nonsense", "--help"], env: noEnv)
        }
    }

    @Test func helpWinsOverWIKIDBEnv() throws {
        let invocation = try ArgumentParser.parse(
            ["source", "--help"], env: { $0 == "WIKI_DB" ? "ENVWIKI" : nil })
        #expect(invocation.wikiSelector.isEmpty)
        #expect(invocation.command == .help(.family("source")))
    }

    @Test func helpTextSurfacesAreNonEmptyAndDistinct() {
        let top = CLIReference.helpText(for: .topLevel)
        let family = CLIReference.helpText(for: .family("source"))
        let leaf = CLIReference.helpText(for: .leaf(family: "source", subcommand: "add", operation: nil))
        #expect(!top.isEmpty && !family.isEmpty && !leaf.isEmpty)
        #expect(top != family && family != leaf)
        for text in [top, family, leaf] {
            #expect(text.contains("usage:"))
            #expect(text.contains("exit status:"))
        }
    }

    // MARK: - Option validation still matches documented behavior

    @Test func documentOptionsStillParse() throws {
        let list = try ArgumentParser.parse(
            ["--wiki", "W", "source", "list", "--json"], env: noEnv)
        #expect(list.command == .source(.list(json: true)))

        let setActive = try ArgumentParser.parse(
            ["--wiki", "W", "source", "set-active", "--id", "01A", "--version-id", "01V"], env: noEnv)
        #expect(setActive.command == .source(.setActive(.id(SourceID(rawValue: "01A")), versionID: SourceMarkdownVersionID(rawValue: "01V"))))

        let provenance = try ArgumentParser.parse(
            ["--wiki", "W", "page", "add", "--title", "T", "--body-file", "-",
             "--source", "01A", "--source", "01B:supporting"], env: noEnv)
        guard case .page(.add(_, _, _, _, _, _, let provenanceSources)) = provenance.command else {
            Issue.record("expected .page(.add)")
            return
        }
        #expect(provenanceSources.count == 2)
    }
}
