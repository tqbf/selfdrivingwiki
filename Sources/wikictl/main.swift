import Foundation
import WikiCtlCore
import WikiFSCore

/// `wikictl` — the agent's write path into a wiki (`plans/llm-wiki.md` Phase A).
///
/// Reads happen via the read-only File Provider mount; WRITES go through this CLI
/// straight to the wiki's `<ulid>.sqlite` in the App Group container. It opens the
/// DB READ-WRITE via the literal App Group path the un-sandboxed app uses (WAL +
/// `busy_timeout=5000` make a second writer process safe), runs one `page`
/// command, prints its output to stdout, and — after any committing call — posts
/// a per-wiki Darwin notification so the app refreshes. It NEVER signals the File
/// Provider itself (single-owner invariant) and NEVER writes the mount.
///
/// Exit codes: 0 success, 2 usage error, 1 runtime error.
func run() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())

    let invocation: ArgumentParser.Invocation
    do {
        invocation = try ArgumentParser.parse(arguments) { ProcessInfo.processInfo.environment[$0] }
    } catch let failure as ArgumentParser.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n\n\(ArgumentParser.usageText)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 2
    }

    do {
        let resolver = try WikiResolver.appGroupContainer()
        guard let descriptor = resolver.descriptor(forSelector: invocation.wikiSelector) else {
            throw PageCommand.Failure.message(
                "no wiki matching \(invocation.wikiSelector.debugDescription) in the registry")
        }
        let store = try SQLiteWikiStore(databaseURL: resolver.databaseURL(for: descriptor))

        let result = try execute(invocation.command, in: store)

        switch result.payload {
        case .text(let output):
            if !output.isEmpty { print(output) }
        case .bytes(let data):
            FileHandle.standardOutput.write(data)
        }
        // Post the change notification ONLY after a committing write, so a read
        // never wakes the app's change bridge.
        if result.didCommit {
            DarwinNotifier.postChange(forWikiID: descriptor.id)
        }
        return 0
    } catch let failure as PageCommand.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n".utf8))
        return 1
    } catch let failure as SourceCommand.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

/// Execute a parsed `Command`, dispatching to `PageCommand` (the `page …` family),
/// `LogIndexCommand` (the Phase-B `log append` / `index set`), or `SourceCommand`
/// (the `source …` family for raw source reads). The deferred body read (`-` = stdin,
/// else a file path) happens here — the only I/O the parser left for `main`.
func execute(_ command: ArgumentParser.Command, in store: SQLiteWikiStore) throws -> SourceCommand.Result {
    switch command {
    case .list(let json):
        let r = try PageCommand.run(.list(json: json), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .get(let selector):
        let r = try PageCommand.run(.get(selector), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .delete(let id):
        let r = try PageCommand.run(.delete(id: id), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .upsert(let id, let title, let bodyFile):
        let body = try readBody(from: bodyFile)
        let r = try PageCommand.run(.upsert(id: id, title: title, body: body), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .logAppend(let kind, let title, let note, let source):
        let r = try LogIndexCommand.run(.logAppend(kind: kind, title: title, note: note, source: source), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .indexSet(let bodyFile):
        let body = try readBody(from: bodyFile)
        let r = try LogIndexCommand.run(.indexSet(body: body), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .search(let query, let limit):
        let r = try PageCommand.run(.search(query: query, limit: limit), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .source(let action):
        return try SourceCommand.run(action, in: store,
                                   cwd: FileManager.default.currentDirectoryPath)
    case .sourceEditMarkdown(let selector, let contentOrFile, let isFile):
        let content: String
        if isFile {
            content = try readBody(from: contentOrFile)
        } else {
            content = contentOrFile
        }
        return try SourceCommand.run(
            .editMarkdown(selector, content: content), in: store,
            cwd: FileManager.default.currentDirectoryPath)
    case .sourceRename(let selector, let to):
        return try SourceCommand.run(
            .rename(selector, to: to), in: store,
            cwd: FileManager.default.currentDirectoryPath)
    case .sourceSetActive(let selector, let versionID):
        return try SourceCommand.run(
            .setActive(selector, versionID: versionID), in: store,
            cwd: FileManager.default.currentDirectoryPath)
    }
}

/// Read an upsert body: `-` reads stdin to EOF; anything else is a file path.
func readBody(from source: String) throws -> String {
    if source == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
    return try String(contentsOfFile: source, encoding: .utf8)
}

exit(run())
