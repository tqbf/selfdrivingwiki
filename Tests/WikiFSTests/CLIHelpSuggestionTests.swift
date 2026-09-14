import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Contextual `help[]` trailers are generated from the same command reference
/// that validates parser input. Replace runtime placeholders before parsing the
/// suggested command to prove every template is executable.
struct CLIHelpSuggestionTests {

    @Test func pageAddSuggestsCASReadAndHistory() {
        let command = ArgumentParser.Command.page(
            .add(id: nil, title: "Notes", body: .file("-")))

        let trailer = CLIReference.helpTrailer(for: command)

        #expect(trailer == "help[]\n  wikictl page get --id <id> --json\n  wikictl page history --id <id>\n")
    }

    @Test func sourceAddSuggestsMarkdownReadAndSearch() {
        let command = ArgumentParser.Command.source(
            .addFile(path: "document.pdf", name: nil))

        let trailer = CLIReference.helpTrailer(for: command)

        #expect(trailer == "help[]\n  wikictl source cat --id <id> --markdown\n  wikictl source search --query <text>\n")
    }

    @Test func sourceURLAddSuggestsRefreshInsteadOfGenericSearch() {
        let command = ArgumentParser.Command.source(
            .addURL("https://example.com/article", allowDuplicateURL: false))

        let trailer = CLIReference.helpTrailer(for: command)

        #expect(trailer == "help[]\n  wikictl source cat --id <id> --markdown\n  wikictl source refresh --id <id>\n")
    }

    @Test func emptySearchResultsSuggestCreation() {
        let page = ArgumentParser.Command.page(.search(query: "missing", limit: 10))
        let source = ArgumentParser.Command.source(.search(query: "missing", limit: 10))

        #expect(CLIReference.helpTrailer(for: page, output: "") ==
                "help[]\n  wikictl page add --title <title> --body-file -\n")
        #expect(CLIReference.helpTrailer(for: source, output: "") ==
                "help[]\n  wikictl source add --body-file <path> --name <name>\n")
        #expect(CLIReference.helpTrailer(for: page, output: "01PAGE\tFound") == nil)
    }

    @Test func emptyTextListsSuggestCreationButJSONListsStayClean() {
        #expect(CLIReference.helpTrailer(
            for: .page(.list(json: false)), output: "") ==
                "help[]\n  wikictl page add --title <title> --body-file -\n")
        #expect(CLIReference.helpTrailer(
            for: .source(.list(json: false)), output: "") ==
                "help[]\n  wikictl source add --body-file <path> --name <name>\n")
        #expect(CLIReference.helpTrailer(
            for: .page(.list(json: true)), output: "") == nil)
        #expect(CLIReference.helpTrailer(
            for: .source(.list(json: true)), output: "") == nil)
    }

    @Test func runnerAppendsOnlyToStderrAndPreservesTextStdout() {
        let command = ArgumentParser.Command.page(
            .add(id: nil, title: "Notes", body: .file("-")))
        let output = WikiCtlRunner.output(
            for: SourceCommand.Result(payload: .text("01PAGE"), didCommit: true),
            command: command)

        #expect(String(decoding: output.stdout, as: UTF8.self) == "01PAGE\n")
        #expect(String(decoding: output.stderr, as: UTF8.self).hasPrefix("help[]\n"))
        #expect(String(decoding: output.stderr, as: UTF8.self).contains(
            "wikictl page get --id <id> --json"))
    }

    @Test func everySuggestionParsesAfterMaskingRuntimePlaceholders() throws {
        let commands: [ArgumentParser.Command] = [
            .page(.add(id: nil, title: "Notes", body: .file("-"))),
            .page(.search(query: "missing", limit: 10)),
            .source(.addFile(path: "document.pdf", name: nil)),
            .source(.addURL("https://example.com/article", allowDuplicateURL: true)),
            .source(.search(query: "missing", limit: 10)),
        ]

        for command in commands {
            guard let trailer = CLIReference.helpTrailer(for: command, output: "") else {
                continue
            }
            for line in trailer.split(separator: "\n").dropFirst() {
                let tokens = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                    .dropFirst()
                    .map { token in
                        token.replacingOccurrences(of: "<id>", with: "01PLACEHOLDER")
                            .replacingOccurrences(of: "<title>", with: "Title")
                            .replacingOccurrences(of: "<text>", with: "text")
                            .replacingOccurrences(of: "<path>", with: "body.md")
                            .replacingOccurrences(of: "<name>", with: "name")
                            .replacingOccurrences(of: "<workspace>", with: "workspace")
                    }
                _ = try ArgumentParser.parse(
                    ["--wiki", "W"] + tokens,
                    env: { _ in nil })
            }
        }
    }
}
