import Testing
@testable import WikiCtlCore

/// The fixture-binary split's rejection contract (plans/cli-domain-commands.md
/// §"The fixture binary"): the shipping `wikictl` has NO local database
/// pathway, so `--database-path` and `WIKI_DB_PATH` are usage errors (exit 2)
/// that name the build-only `wikictl-fixture` binary. Help never mentions
/// them (the help text is generated from `CLIReference`, which never listed
/// the selector).
@Suite("wikictl rejects the fixture selector")
struct WikiCtlFixtureFlagRejectionTests {

    private static func usageText(_ error: Error) -> String {
        (error as? ArgumentParser.Failure)?.description ?? String(describing: error)
    }

    @Test("--database-path is rejected with the fixture-binary pointer", arguments: [
        ["--database-path", "/tmp/eval.sqlite", "page", "list"],
        ["--database-path=/tmp/eval.sqlite", "page", "list"],
    ])
    func rejectsFlagForm(arguments: [String]) {
        do {
            _ = try ArgumentParser.parse(arguments) { _ in nil }
            Issue.record("expected the fixture-selector usage error")
        } catch {
            let text = Self.usageText(error)
            #expect(text.contains("--database-path was removed from wikictl"))
            #expect(text.contains("wikictl-fixture"))
        }
    }

    @Test("WIKI_DB_PATH is rejected with the fixture-binary pointer")
    func rejectsEnvForm() {
        do {
            _ = try ArgumentParser.parse(["page", "list"]) { name in
                name == "WIKI_DB_PATH" ? "/tmp/eval.sqlite" : nil
            }
            Issue.record("expected the fixture-selector usage error")
        } catch {
            let text = Self.usageText(error)
            #expect(text.contains("WIKI_DB_PATH was removed from wikictl"))
            #expect(text.contains("wikictl-fixture"))
        }
    }

    @Test("the flag wins over an accompanying --wiki (still rejected)")
    func rejectsMixedForm() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(
                ["--wiki", "01WIKI", "--database-path", "/tmp/eval.sqlite", "page", "list"]
            ) { _ in nil }
        }
    }

    @Test("the no-selector usage error no longer mentions the fixture selector")
    func noSelectorMessageIsRegistryOnly() {
        do {
            _ = try ArgumentParser.parse(["page", "list"]) { _ in nil }
            Issue.record("expected the no-selector usage error")
        } catch {
            let text = Self.usageText(error)
            #expect(text.contains("no wiki selected"))
            #expect(!text.contains("database-path"))
            #expect(!text.contains("WIKI_DB_PATH"))
        }
    }

    @Test("ordinary --wiki parsing is unchanged")
    func parsesWikiSelectorUnchanged() throws {
        let flagged = try ArgumentParser.parse(["--wiki", "01WIKI", "page", "list"]) { _ in nil }
        #expect(flagged.wikiSelector == "01WIKI")

        let fromEnv = try ArgumentParser.parse(["page", "list"]) { name in
            name == "WIKI_DB" ? "01WIKI" : nil
        }
        #expect(fromEnv.wikiSelector == "01WIKI")
    }
}
