import Foundation

/// The body source for commands that accept a markdown body either inline or
/// from a file (path or `-` for stdin). Lets the parser produce an executable
/// `Action` directly — the action's `run` resolves the body to a `String`
/// once, just before the write. Mirrors the deferral the flat `Command.upsert`
/// / `Command.sourceEditMarkdown` cases used to carry, now folded under
/// `.page(.add(...))` / `.source(.editMarkdown(...))`.
public enum BodySource: Equatable, Sendable {
    /// The body is the literal string.
    case inline(String)
    /// The body is read from `path` (or `-` for stdin) at execution time.
    case file(String)
}

/// Resolve a `BodySource` to its final `String` form. `-` reads stdin to EOF;
/// any other `file` value is a UTF-8 file path. `inline` returns the literal.
/// Errors propagate to the caller — the parser layer routes failures through
/// `PageCommand.Failure.message` / `SourceCommand.Failure.message` so they
/// surface with a clear, agent-actionable message at the CLI boundary.
public func resolveBodySource(_ source: BodySource) throws -> String {
    switch source {
    case .inline(let text):
        return text
    case .file(let path):
        return try readBodyFile(from: path)
    }
}

/// Read a body from a path or `-` (stdin). Shared by `resolveBodySource` and
/// the historical `LogIndexCommand.indexSet` path (which still uses a raw
/// `bodyFile: String`). `-` reads stdin to EOF; anything else is a UTF-8
/// file path.
public func readBodyFile(from source: String) throws -> String {
    if source == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
    return try String(contentsOfFile: source, encoding: .utf8)
}
