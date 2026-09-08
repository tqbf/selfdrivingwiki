import Foundation

/// Which help surface to print. `leaf` carries an `operation` only for the
/// nested OKF operations (`wikictl page okf verify --help`).
public enum CLIHelpScope: Equatable, Sendable {
    case topLevel
    /// A top-level command that is not a family: `version`, `--dump-config`.
    case topLevelCommand(String)
    /// A command family: `page`, `source`, `chat`, …
    case family(String)
    /// One leaf command (`source add`), with the OKF operation when given.
    case leaf(family: String, subcommand: String, operation: String?)
}

/// The spec-driven description of the `wikictl` command surface (#1224).
///
/// This is the SINGLE SOURCE OF TRUTH for three layers that used to be
/// hand-maintained separately (and could drift):
///
/// 1. **Routing** — `ArgumentParser` recognizes exactly the families and
///    leaves listed here; unknown ones get an error generated from this table.
/// 2. **Option validation** — the parser's `Options` bag accepts exactly the
///    options listed for the command being parsed; anything else is a loud
///    usage error instead of being silently ignored.
/// 3. **Help** — `wikictl [--wiki <id>] [<command> [<subcommand>]] --help`
///    prints help generated from this table, so a command's help can never
///    disagree with what the parser actually accepts.
///
/// The table is data on purpose: adding a subcommand means adding one entry,
/// and parsing, option checking, and help all pick it up together.
public enum CLIReference {

    public static let programName = "wikictl"

    // MARK: - Spec model

    /// One option in a command signature. `signature` is the help-table form:
    /// `"--json"` for a boolean flag, `"--body-file <path|->"` for an option
    /// that takes a value. The name is everything before the first space.
    public struct CLIOption: Equatable, Sendable {
        public let signature: String
        public let required: Bool
        public let repeated: Bool
        public let summary: String

        public init(
            _ signature: String, required: Bool = false,
            repeated: Bool = false, summary: String
        ) {
            self.signature = signature
            self.required = required
            self.repeated = repeated
            self.summary = summary
        }

        public var name: String {
            String(signature.split(separator: " ", maxSplits: 1)[0])
        }
        public var takesValue: Bool { signature.contains(" ") }
    }

    /// One nested OKF operation (`inspect`, `status`, `freshness`, `verify`,
    /// `correct`). Shared verbatim between `page okf` and `source okf`; the
    /// only difference between the two families is the version-id kind, which
    /// the leaf's command line states.
    public struct CLIOperation: Equatable, Sendable {
        public let name: String
        public let summary: String
        public let usage: String
        public let options: [CLIOption]

        public init(name: String, summary: String, usage: String, options: [CLIOption]) {
            self.name = name
            self.summary = summary
            self.usage = usage
            self.options = options
        }
    }

    /// One leaf command (`source add`). `commandLine` is the usage form
    /// WITHOUT the family prefix (`add (--url URL | --body-file <path|->)`);
    /// help tables render it as `<family> <commandLine>`.
    public struct CLILeaf: Equatable, Sendable {
        public let name: String
        public let summary: String
        public let commandLine: String
        public let options: [CLIOption]
        public let details: [String]
        public let examples: [String]
        public let operations: [CLIOperation]?

        public init(
            _ name: String, summary: String, commandLine: String,
            options: [CLIOption] = [], details: [String] = [],
            examples: [String] = [], operations: [CLIOperation]? = nil
        ) {
            self.name = name
            self.summary = summary
            self.commandLine = commandLine
            self.options = options
            self.details = details
            self.examples = examples
            self.operations = operations
        }
    }

    /// One command family (`source`).
    public struct CLIFamily: Equatable, Sendable {
        public let name: String
        public let summary: String
        public let leaves: [CLILeaf]

        public init(name: String, summary: String, leaves: [CLILeaf]) {
            self.name = name
            self.summary = summary
            self.leaves = leaves
        }

        public func leaf(named name: String) -> CLILeaf? {
            leaves.first { $0.name == name }
        }

        /// The union of every leaf's options, first-seen order. This is the
        /// option set the parser accepts across the family (leaf parsers
        /// validate required values and semantics themselves).
        public var allOptions: [CLIOption] {
            var seen = Set<String>()
            var result: [CLIOption] = []
            for leaf in leaves {
                for option in leaf.options where !seen.contains(option.name) {
                    seen.insert(option.name)
                    result.append(option)
                }
            }
            return result
        }
    }

    // MARK: - Shared OKF operations

    /// The five OKF operations, shared by `page okf` and `source okf`.
    public static let okfOperations: [CLIOperation] = [
        CLIOperation(
            name: "inspect",
            summary: "print the OKF metadata recorded on one exact version",
            usage: "inspect --version <version-id> [--json]",
            options: [
                CLIOption("--version <version-id>", required: true, summary: "the exact version to inspect"),
                CLIOption("--json", summary: "print JSON instead of TSV"),
            ]),
        CLIOperation(
            name: "status",
            summary: "set or clear the concept status (draft | stable | deprecated)",
            usage: "status --version <version-id> (--status <draft|stable|deprecated> | --clear)",
            options: [
                CLIOption("--version <version-id>", required: true, summary: "the exact version to stamp"),
                CLIOption("--status <draft|stable|deprecated>", summary: "the status to set"),
                CLIOption("--clear", summary: "unset the status"),
            ]),
        CLIOperation(
            name: "freshness",
            summary: "set or clear the freshness policy on one exact version",
            usage: "freshness --version <version-id> (--stale-after <ISO-8601> | --ttl <30s|15m|24h|7d> [--anchor generated|verification] [--verification ID] | --clear)",
            options: [
                CLIOption("--version <version-id>", required: true, summary: "the exact version to stamp"),
                CLIOption("--stale-after <ISO-8601>", summary: "fixed stale-at timestamp"),
                CLIOption("--ttl <30s|15m|24h|7d>", summary: "time-to-live from the anchor"),
                CLIOption("--anchor <generated|verification>", summary: "what the TTL counts from (default generated)"),
                CLIOption("--verification <id>", summary: "verification the `verification` anchor counts from"),
                CLIOption("--clear", summary: "unset the freshness policy"),
            ]),
        CLIOperation(
            name: "verify",
            summary: "record a verification (who, when, on what basis)",
            usage: "verify --version <version-id> --by <actor> --basis <kind> [--at <ISO-8601>] [--evidence source:ID|url:URL …] [--note TEXT] [--ttl DURATION]",
            options: [
                CLIOption("--version <version-id>", required: true, summary: "the exact version to verify"),
                CLIOption("--by <actor>", required: true, summary: "verifier identity (user | agent:<kind> | chat:<id>)"),
                CLIOption("--at <ISO-8601>", summary: "verification time (default: command time)"),
                CLIOption("--basis <kind>", required: true, summary: "human-review | source-checked | external-revalidation"),
                CLIOption("--evidence <source:ID|url:URL>", repeated: true, summary: "evidence citation; repeatable"),
                CLIOption("--note <text>", summary: "free-text note on the verification"),
                CLIOption("--ttl <duration>", summary: "also set verification-anchored freshness"),
            ]),
        CLIOperation(
            name: "correct",
            summary: "record a correction against an existing verification",
            usage: "correct --verification ID --by <actor> [--at <ISO-8601>] [--reason TEXT]",
            options: [
                CLIOption("--version <version-id>", required: true, summary: "the exact version the correction applies to"),
                CLIOption("--verification <id>", required: true, summary: "the verification being corrected"),
                CLIOption("--by <actor>", required: true, summary: "corrector identity (user | agent:<kind> | chat:<id>)"),
                CLIOption("--at <ISO-8601>", summary: "correction time (default: command time)"),
                CLIOption("--reason <text>", summary: "why the verification was corrected"),
            ]),
    ]

    /// One-line-per-operation block printed under the okf leaves (matches the
    /// long-standing usage-text wording for the timestamp default).
    public static let okfOperationsNote =
        "Verification/correction timestamps default to command time when --at is omitted."

    // MARK: - The command tree

    public static let topLevelCommands: [CLILeaf] = [
        CLILeaf(
            "version", summary: "print build version info; --json for machine-readable",
            commandLine: "version [--json]",
            options: [CLIOption("--json", summary: "machine-readable output")],
            details: [
                "Needs no wiki selection. Also available as --version / -v.",
                "Reports the resolved App Group id and WHERE it came from — check this first when every wiki lookup fails.",
            ]),
        CLILeaf(
            "--dump-config", summary: "print the resolved Cordis profile",
            commandLine: "--dump-config [--patch <yaml>]",
            options: [CLIOption("--patch <yaml>", summary: "apply a YAML overlay before resolving")],
            details: ["Needs no wiki selection. Prints the effective agent/provider profile after overlays."]),
    ]

    public static let families: [CLIFamily] = [
        CLIFamily(
            name: "page",
            summary: "create, read, search, and version wiki pages",
            leaves: [
                CLILeaf(
                    "list", summary: "list pages (TSV, or JSON lines)",
                    commandLine: "list [--json]",
                    options: [CLIOption("--json", summary: "one JSON object per line instead of TSV")]),
                CLILeaf(
                    "get", summary: "print a page body; --json adds head_version_id; --workspace W reads the staged version",
                    commandLine: "get (--title X | --id Y) [--json] [--workspace W]",
                    options: [
                        CLIOption("--title <title>", summary: "page selector — exactly one of --title / --id"),
                        CLIOption("--id <page-id>", summary: "page selector — exactly one of --title / --id"),
                        CLIOption("--json", summary: "prefix the body with head_version_id for CAS reads"),
                        CLIOption("--workspace <name>", summary: "read the staged version in workspace W"),
                    ],
                    details: ["In text mode head_version_id goes to stderr; pipe it into `page add --expect-head`."],
                    examples: [
                        "wikictl page get --title Home",
                        "wikictl page get --id 01ABC --json",
                    ]),
                CLILeaf(
                    "add",
                    summary: "create-or-update a page; --expect-head enables CAS (exit 3 on conflict)",
                    commandLine: "add --title X [--id Y] --body-file <path|-> [--expect-head <ver>] [--workspace W] [--author <who>] [--source <source-id[:role]> …]",
                    options: [
                        CLIOption("--title <title>", required: true, summary: "page title; the create-or-update key"),
                        CLIOption("--id <page-id>", summary: "target an existing page by id instead of by title"),
                        CLIOption("--body-file <path|->", required: true, summary: "markdown body; `-` reads stdin — use a pipe or heredoc"),
                        CLIOption("--expect-head <ver>", summary: "CAS: fail with exit 3 if HEAD moved since your read"),
                        CLIOption("--workspace <name>", summary: "write into workspace W instead of main"),
                        CLIOption("--author <who>", summary: "stamp created_by/last_edited_by (default: WIKI_AUTHOR env)"),
                        CLIOption("--source <source-id[:role]>", repeated: true, summary: "provenance stamp; repeatable, role defaults to primary"),
                    ],
                    details: [
                        "CAS discipline: read head_version_id first (`page get --json`, or the stderr line in text mode), pass it as --expect-head; on exit 3 re-read, reapply, and retry once.",
                        "On success the write echoes the new head_version_id on stderr, so the next CAS write needs no extra read.",
                        "--author accepts `chat:<id>`, `agent:<kind>`, or a plain name; the WIKI_AUTHOR env fills it when omitted.",
                    ],
                    examples: [
                        "wikictl page add --title \"Meeting Notes\" --body-file notes.md",
                        "cat draft.md | wikictl page add --title Draft --body-file -",
                        "wikictl page add --title Draft --body-file - --expect-head 01ABC --author chat:01XYZ",
                    ]),
                CLILeaf(
                    "delete", summary: "delete a page",
                    commandLine: "delete --id Y",
                    options: [CLIOption("--id <page-id>", required: true, summary: "the page to delete")]),
                CLILeaf(
                    "search", summary: "semantic search (cosine similarity); falls back to LIKE title match",
                    commandLine: "search --query X [--limit N]",
                    options: [
                        CLIOption("--query <text>", required: true, summary: "what to search for"),
                        CLIOption("--limit <n>", summary: "max results, 1–100 (default 10)"),
                    ]),
                CLILeaf(
                    "history", summary: "show version history (W0)",
                    commandLine: "history (--title X | --id Y)",
                    options: [
                        CLIOption("--title <title>", summary: "page selector — exactly one of --title / --id"),
                        CLIOption("--id <page-id>", summary: "page selector — exactly one of --title / --id"),
                    ]),
                CLILeaf(
                    "revert", summary: "revert a page to version V (W0)",
                    commandLine: "revert (--title X | --id Y) --version V",
                    options: [
                        CLIOption("--title <title>", summary: "page selector — exactly one of --title / --id"),
                        CLIOption("--id <page-id>", summary: "page selector — exactly one of --title / --id"),
                        CLIOption("--version <ver>", required: true, summary: "the version to revert to"),
                    ]),
                CLILeaf(
                    "info",
                    summary: "print page identity + origin provenance (HEAD's agent/activity + full edit history)",
                    commandLine: "info (--title X | --id Y)",
                    options: [
                        CLIOption("--title <title>", summary: "page selector — exactly one of --title / --id"),
                        CLIOption("--id <page-id>", summary: "page selector — exactly one of --title / --id"),
                    ]),
                CLILeaf(
                    "okf", summary: "inspect or author exact-version OKF metadata",
                    commandLine: "okf <operation> --version <page-version-id> [options]",
                    details: [okfOperationsNote],
                    operations: okfOperations),
            ]),
        CLIFamily(
            name: "log",
            summary: "append dated rows to the wiki log (log.md)",
            leaves: [
                CLILeaf(
                    "append", summary: "append one dated row to log.md; --source stamps that file \"Processed\"",
                    commandLine: "append --kind ingest|query|lint --title X [--note N] [--source <file-id>]",
                    options: [
                        CLIOption("--kind <ingest|query|lint>", required: true, summary: "row kind"),
                        CLIOption("--title <title>", required: true, summary: "row title"),
                        CLIOption("--note <note>", summary: "optional extra text"),
                        CLIOption("--source <file-id>", summary: "mark this ingested file as Processed"),
                    ],
                    examples: [
                        "wikictl log append --kind ingest --title \"report.pdf\" --source 01ABC",
                    ]),
            ]),
        CLIFamily(
            name: "index",
            summary: "rewrite the curated index page (index.md)",
            leaves: [
                CLILeaf(
                    "set", summary: "rewrite the curated index.md body; --workspace W stages into workspace W",
                    commandLine: "set --body-file <path|-> [--workspace W]",
                    options: [
                        CLIOption("--body-file <path|->", required: true, summary: "full replacement body; `-` reads stdin — use a pipe or heredoc"),
                        CLIOption("--workspace <name>", summary: "stage into workspace W instead of main"),
                    ],
                    examples: ["wikictl index set --body-file ./index.md"]),
            ]),
        CLIFamily(
            name: "source",
            summary: "ingest, read, edit, and search raw sources",
            leaves: [
                CLILeaf(
                    "list", summary: "list sources (TSV, or JSON lines)",
                    commandLine: "list [--json]",
                    options: [CLIOption("--json", summary: "one JSON object per line instead of TSV")]),
                CLILeaf(
                    "add", summary: "fetch a URL or add raw file/stdin bytes; use --body-file - with a pipe or heredoc; --name is required for stdin",
                    commandLine: "add (--url URL [--allow-duplicate] | --body-file <path|-> [--name NAME])",
                    options: [
                        CLIOption("--url <URL>", summary: "fetch a web page — exactly one of --url / --body-file"),
                        CLIOption("--body-file <path|->", summary: "raw bytes from a file; `-` reads stdin — exactly one of --url / --body-file"),
                        CLIOption("--name <name>", summary: "display name; required when --body-file is -"),
                        CLIOption("--allow-duplicate", summary: "permit a URL already in the wiki (--url only)"),
                    ],
                    examples: [
                        "wikictl source add --url https://example.com/article",
                        "cat photo.png | wikictl source add --name photo.png --body-file -",
                    ]),
                CLILeaf(
                    "cat", summary: "write raw source bytes (or extracted markdown with --markdown) to stdout",
                    commandLine: "cat (--id X | --name N) [--markdown]",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--markdown", summary: "emit the extracted/processed markdown instead of raw bytes"),
                    ]),
                CLILeaf(
                    "export", summary: "materialize a source to disk, print its path; --markdown exports the .md sibling",
                    commandLine: "export (--id X | --name N) [--out <path>] [--markdown]",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--out <path>", summary: "destination path (default: <cwd>/file-<id>.<ext>)"),
                        CLIOption("--markdown", summary: "export the processed-markdown sibling instead"),
                    ]),
                CLILeaf(
                    "edit-markdown", summary: "replace the processed-markdown HEAD",
                    commandLine: "edit-markdown (--id X | --name N) (--content <md> | --file <path|->)",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--content <md>", summary: "inline replacement — exactly one of --content / --file"),
                        CLIOption("--file <path|->", summary: "replacement from a file or stdin — exactly one of --content / --file"),
                    ]),
                CLILeaf(
                    "search", summary: "semantic search of sources (cosine; falls back to LIKE name match)",
                    commandLine: "search --query X [--limit N]",
                    options: [
                        CLIOption("--query <text>", required: true, summary: "what to search for"),
                        CLIOption("--limit <n>", summary: "max results, 1–100 (default 10)"),
                    ]),
                CLILeaf(
                    "set-active", summary: "nominate a processed-markdown version as the active HEAD (extraction alt)",
                    commandLine: "set-active (--id X | --name N) --version <smv-id>",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--version <smv-id>", required: true, summary: "the markdown version to make active"),
                        CLIOption("--version-id <smv-id>", summary: "legacy alias for --version"),
                    ]),
                CLILeaf(
                    "info", summary: "print source identity + processing provenance",
                    commandLine: "info (--id X | --name N)",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                    ]),
                CLILeaf(
                    "rename", summary: "rename a source's display name",
                    commandLine: "rename (--id X | --name N) --to <new-name>",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--to <new-name>", required: true, summary: "the new display name"),
                    ]),
                CLILeaf(
                    "refresh", summary: "re-fetch a website source via its provider, appending a new version",
                    commandLine: "refresh (--id X | --name N)",
                    options: [
                        CLIOption("--id <source-id>", summary: "source selector — exactly one of --id / --name"),
                        CLIOption("--name <name>", summary: "source selector — exactly one of --id / --name"),
                    ]),
                CLILeaf(
                    "okf", summary: "inspect or author exact-version OKF metadata",
                    commandLine: "okf <operation> --version <source-markdown-version-id> [options]",
                    details: [okfOperationsNote],
                    operations: okfOperations),
            ]),
        CLIFamily(
            name: "admin",
            summary: "maintenance operations (vacuum, MIME repair)",
            leaves: [
                CLILeaf(
                    "vacuum-blobs", summary: "report (and with --apply, reclaim) blobs no version row references",
                    commandLine: "vacuum-blobs [--apply] [--json]",
                    options: [
                        CLIOption("--apply", summary: "delete instead of dry-run"),
                        CLIOption("--json", summary: "machine-readable report"),
                    ]),
                CLILeaf(
                    "vacuum-activities", summary: "report (and with --apply, reclaim) activities no version row references",
                    commandLine: "vacuum-activities [--apply] [--json]",
                    options: [
                        CLIOption("--apply", summary: "delete instead of dry-run"),
                        CLIOption("--json", summary: "machine-readable report"),
                    ]),
                CLILeaf(
                    "vacuum-page-versions", summary: "report (and with --apply, reclaim) page versions no ref/workspace references",
                    commandLine: "vacuum-page-versions [--apply] [--json]",
                    options: [
                        CLIOption("--apply", summary: "delete instead of dry-run"),
                        CLIOption("--json", summary: "machine-readable report"),
                    ]),
                CLILeaf(
                    "vacuum-all", summary: "report (and with --apply, reclaim) orphaned blobs, activities, and page versions",
                    commandLine: "vacuum-all [--apply] [--json]",
                    options: [
                        CLIOption("--apply", summary: "delete instead of dry-run"),
                        CLIOption("--json", summary: "machine-readable report"),
                    ]),
                CLILeaf(
                    "repair-mime", summary: "detect active NULL MIME values (dry-run unless --apply is present)",
                    commandLine: "repair-mime [--apply] [--json]",
                    options: [
                        CLIOption("--apply", summary: "backfill instead of dry-run"),
                        CLIOption("--json", summary: "machine-readable report"),
                    ]),
            ]),
        CLIFamily(
            name: "chat",
            summary: "read and search persisted chat transcripts (live chat is app-only)",
            leaves: [
                CLILeaf(
                    "list", summary: "list chats (TSV, or JSON lines)",
                    commandLine: "list [--json]",
                    options: [CLIOption("--json", summary: "one JSON object per line instead of TSV")]),
                CLILeaf(
                    "get", summary: "print a chat transcript as markdown",
                    commandLine: "get (--id X | --title T)",
                    options: [
                        CLIOption("--id <chat-id>", summary: "chat selector — exactly one of --id / --title"),
                        CLIOption("--title <title>", summary: "chat selector — exactly one of --id / --title"),
                    ]),
                CLILeaf(
                    "search", summary: "semantic + keyword search of chats",
                    commandLine: "search --query X [--limit N]",
                    options: [
                        CLIOption("--query <text>", required: true, summary: "what to search for"),
                        CLIOption("--limit <n>", summary: "max results, 1–100 (default 10)"),
                    ]),
                CLILeaf(
                    "rename", summary: "rename a chat",
                    commandLine: "rename (--id X | --title T) --to <new-title>",
                    options: [
                        CLIOption("--id <chat-id>", summary: "chat selector — exactly one of --id / --title"),
                        CLIOption("--title <title>", summary: "chat selector — exactly one of --id / --title"),
                        CLIOption("--to <new-title>", required: true, summary: "the new title"),
                    ]),
                CLILeaf(
                    "new", summary: "start a live chat session (app-only; fails from the CLI)",
                    commandLine: "new --message <text>",
                    options: [CLIOption("--message <text>", required: true, summary: "opening message")],
                    details: [
                        "Live chat is only available in the app — the wikid daemon is an app-bound XPC service a short-lived CLI process cannot reach. Use the app to start chats; use `chat list`/`chat get` to read them here.",
                    ]),
                CLILeaf(
                    "send", summary: "send a message to a live chat (app-only; fails from the CLI)",
                    commandLine: "send --chat-id <id> --message <text>",
                    options: [
                        CLIOption("--chat-id <id>", required: true, summary: "the chat to send to"),
                        CLIOption("--message <text>", required: true, summary: "the message"),
                    ],
                    details: ["Retired — see `chat new`."]),
                CLILeaf(
                    "stop", summary: "stop a live chat session (app-only; fails from the CLI)",
                    commandLine: "stop --chat-id <id>",
                    options: [CLIOption("--chat-id <id>", required: true, summary: "the chat to stop")],
                    details: ["Retired — see `chat new`."]),
            ]),
        CLIFamily(
            name: "bookmark",
            summary: "manage the bookmark tree (folders + page/source/chat refs)",
            leaves: [
                CLILeaf(
                    "list", summary: "list bookmark nodes (TSV, or JSON)",
                    commandLine: "list [--json]",
                    options: [CLIOption("--json", summary: "one JSON object per line instead of TSV")]),
                CLILeaf(
                    "create-folder", summary: "create a bookmark folder",
                    commandLine: "create-folder [--parent ID] --name <name>",
                    options: [
                        CLIOption("--parent <node-id>", summary: "parent folder (default: root)"),
                        CLIOption("--name <name>", required: true, summary: "the folder name"),
                    ]),
                CLILeaf(
                    "add-ref", summary: "add a page/source/chat ref to bookmarks",
                    commandLine: "add-ref [--parent ID] --kind <page|source|chat> --target <id>",
                    options: [
                        CLIOption("--parent <node-id>", summary: "parent folder (default: root)"),
                        CLIOption("--kind <page|source|chat>", required: true, summary: "what kind of ref"),
                        CLIOption("--target <id>", required: true, summary: "the referenced row's id"),
                    ]),
                CLILeaf(
                    "rename", summary: "rename a bookmark folder",
                    commandLine: "rename --id <node-id> --to <new-name>",
                    options: [
                        CLIOption("--id <node-id>", required: true, summary: "the node to rename"),
                        CLIOption("--to <new-name>", required: true, summary: "the new name"),
                    ]),
                CLILeaf(
                    "delete", summary: "delete a bookmark node (cascades)",
                    commandLine: "delete --id <node-id>",
                    options: [CLIOption("--id <node-id>", required: true, summary: "the node to delete")]),
                CLILeaf(
                    "move", summary: "move a bookmark node",
                    commandLine: "move --id <node-id> [--parent ID] [--position N]",
                    options: [
                        CLIOption("--id <node-id>", required: true, summary: "the node to move"),
                        CLIOption("--parent <node-id>", summary: "destination folder (default: root)"),
                        CLIOption("--position <n>", summary: "insert position (default: append to end)"),
                    ]),
            ]),
        CLIFamily(
            name: "workspace",
            summary: "branch-style staged workspaces (create, merge, resolve conflicts)",
            leaves: [
                CLILeaf(
                    "create", summary: "create a workspace (prints ID)",
                    commandLine: "create [--name N]",
                    options: [CLIOption("--name <name>", summary: "optional display name")]),
                CLILeaf(
                    "status", summary: "show workspace status + pages",
                    commandLine: "status --id W",
                    options: [CLIOption("--id <workspace-id>", required: true, summary: "the workspace")]),
                CLILeaf(
                    "abandon", summary: "abandon a workspace (GC refs)",
                    commandLine: "abandon --id W",
                    options: [CLIOption("--id <workspace-id>", required: true, summary: "the workspace")]),
                CLILeaf(
                    "merge", summary: "fast-forward merge into main",
                    commandLine: "merge --id W",
                    options: [CLIOption("--id <workspace-id>", required: true, summary: "the workspace")]),
                CLILeaf(
                    "refresh", summary: "re-base workspace against current main",
                    commandLine: "refresh --id W",
                    options: [CLIOption("--id <workspace-id>", required: true, summary: "the workspace")]),
                CLILeaf(
                    "conflicts", summary: "list per-page conflict details",
                    commandLine: "conflicts --id W",
                    options: [CLIOption("--id <workspace-id>", required: true, summary: "the workspace")]),
                CLILeaf(
                    "resolve", summary: "resolve a conflict with the given body",
                    commandLine: "resolve --id W --page P --body-file <path|->",
                    options: [
                        CLIOption("--id <workspace-id>", required: true, summary: "the workspace"),
                        CLIOption("--page <page-id>", required: true, summary: "the conflicting page"),
                        CLIOption("--body-file <path|->", required: true, summary: "the resolved body; `-` reads stdin"),
                    ]),
                CLILeaf(
                    "retry", summary: "re-open + re-merge after resolving conflicts",
                    commandLine: "retry --id W",
                    options: [CLIOption("--id <workspace-id>", required: true, summary: "the workspace")]),
                CLILeaf(
                    "reap", summary: "abandon stale open workspaces (default 3600s)",
                    commandLine: "reap [--ttl <seconds>]",
                    options: [CLIOption("--ttl <seconds>", summary: "age threshold in seconds (default 3600)")]),
            ]),
        CLIFamily(
            name: "wiki",
            summary: "create, list, rename, and delete whole wikis (registry operations)",
            leaves: [
                CLILeaf(
                    "list", summary: "list registered wikis (id + display name)",
                    commandLine: "list"),
                CLILeaf(
                    "create", summary: "create a wiki (default name \"Untitled Wiki\")",
                    commandLine: "create [--name N]",
                    options: [CLIOption("--name <name>", summary: "display name (default: Untitled Wiki)")]),
                CLILeaf(
                    "delete", summary: "delete a wiki and its database files",
                    commandLine: "delete --id <wiki-id>",
                    options: [CLIOption("--id <wiki-id>", required: true, summary: "the wiki to delete")]),
                CLILeaf(
                    "rename", summary: "rename a wiki",
                    commandLine: "rename --id <wiki-id> --name <new-name>",
                    options: [
                        CLIOption("--id <wiki-id>", required: true, summary: "the wiki to rename"),
                        CLIOption("--name <new-name>", required: true, summary: "the new display name"),
                    ]),
            ]),
    ]

    // MARK: - Lookup helpers

    public static func family(named name: String) -> CLIFamily? {
        families.first { $0.name == name }
    }

    public static func leaf(family familyName: String, named leafName: String) -> CLILeaf? {
        family(named: familyName)?.leaf(named: leafName)
    }

    public static func topLevelCommand(named name: String) -> CLILeaf? {
        topLevelCommands.first { $0.name == name }
    }

    public static func okfOperation(named name: String) -> CLIOperation? {
        okfOperations.first { $0.name == name }
    }

    /// The option set the parser accepts for a family (the union of its
    /// leaves' options). Feeds `ArgumentParser.Options` so parsing and help
    /// share one definition.
    public static func options(forFamily name: String) -> [CLIOption] {
        family(named: name)?.allOptions ?? []
    }

    /// Same, for the non-family top-level commands (`version`, `--dump-config`).
    public static func options(forTopLevelCommand name: String) -> [CLIOption] {
        topLevelCommand(named: name)?.options ?? []
    }

    /// Error text for a family invoked with no subcommand.
    public static func missingSubcommandMessage(familyName: String) -> String {
        "\(familyName): missing subcommand (known: \(leafNames(familyName))) — run `\(programName) \(familyName) --help`"
    }

    /// Error text for an unrecognized subcommand.
    public static func unknownSubcommandMessage(familyName: String, given: String) -> String {
        "\(familyName): unknown subcommand \(given.debugDescription) (known: \(leafNames(familyName))) — run `\(programName) \(familyName) --help`"
    }

    /// Error text for an unrecognized OKF operation.
    public static func unknownOKFOperationMessage(given: String) -> String {
        let names = okfOperations.map(\.name).joined(separator: ", ")
        return "okf: unknown operation \(given.debugDescription) (known: \(names)) — run `\(programName) page okf --help`"
    }

    private static func leafNames(_ familyName: String) -> String {
        family(named: familyName)?.leaves.map(\.name).joined(separator: ", ") ?? ""
    }

    // MARK: - Help interception

    /// Recognizes `--help` / `-h` when it appears on the command path:
    ///
    ///   wikictl --help
    ///   wikictl [--wiki X] source --help
    ///   wikictl [--wiki X] source add --help
    ///   wikictl [--wiki X] page okf verify --help
    ///   wikictl version --help
    ///
    /// Returns nil when the tokens are not a help invocation, so normal
    /// parsing (and its loud usage errors) proceeds untouched. Runs BEFORE
    /// the wiki-selector requirement — help never needs a wiki (#1224).
    public static func resolveHelpScope(_ arguments: [String]) -> CLIHelpScope? {
        let helpTokens: Set<String> = ["--help", "-h"]
        var args = arguments[...]
        // A leading `--wiki <value>` pair selects a wiki; help sits behind it.
        if args.first == "--wiki" { args = args.dropFirst(2) }
        guard let first = args.first else { return nil }

        if helpTokens.contains(first) { return .topLevel }

        // Top-level commands that are not families: `version --help`,
        // `--dump-config --help`.
        if topLevelCommand(named: first) != nil {
            let next = args.dropFirst().first
            return helpTokens.contains(next ?? "") ? .topLevelCommand(first) : nil
        }

        guard let fam = family(named: first) else { return nil }
        guard let second = args.dropFirst().first else { return nil }
        if helpTokens.contains(second) { return .family(fam.name) }

        guard let leaf = fam.leaf(named: second) else { return nil }
        let rest = args.dropFirst(2)
        guard let third = rest.first else { return nil }
        if helpTokens.contains(third) {
            return .leaf(family: fam.name, subcommand: leaf.name, operation: nil)
        }
        // `page okf verify --help` — one level below the okf leaf.
        if let operations = leaf.operations,
            let operation = operations.first(where: { $0.name == third })
        {
            let after = rest.dropFirst().first
            if helpTokens.contains(after ?? "") {
                return .leaf(family: fam.name, subcommand: leaf.name, operation: operation.name)
            }
        }
        return nil
    }

    // MARK: - Help text generation

    public static func helpText(for scope: CLIHelpScope) -> String {
        switch scope {
        case .topLevel:
            return topLevelHelp()
        case .topLevelCommand(let name):
            if let leaf = topLevelCommand(named: name) {
                return leafHelp(header: "\(programName) \(leaf.name)", usagePath: leaf.commandLine, leaf: leaf)
            }
            return topLevelHelp()
        case .family(let name):
            guard let fam = family(named: name) else { return topLevelHelp() }
            return familyHelp(fam)
        case .leaf(let familyName, let subcommand, let operation):
            guard let fam = family(named: familyName), let leaf = fam.leaf(named: subcommand) else {
                return topLevelHelp()
            }
            if let operationName = operation, let op = leaf.operations?.first(where: { $0.name == operationName }) {
                return okfOperationHelp(family: fam, leaf: leaf, operation: op)
            }
            return leafHelp(
                header: "\(programName) \(fam.name) \(leaf.name)",
                usagePath: "\(fam.name) \(leaf.commandLine)",
                leaf: leaf)
        }
    }

    // MARK: Top-level

    private static func topLevelHelp() -> String {
        var lines: [String] = []
        lines.append("usage: \(programName) [--wiki <id>] <command>")
        lines.append("       \(programName) <command> <subcommand> --help")
        lines.append("")
        lines.append("Selects the wiki by --wiki <id-or-name> or the WIKI_DB env var.")
        lines.append("`version` / `--version` / `-v` prints build info. Help never needs a wiki.")
        lines.append("")
        lines.append("commands:")

        var rows: [(String, String)] = topLevelCommands.map { ($0.commandLine, $0.summary) }
        for fam in families {
            for leaf in fam.leaves {
                rows.append(("\(fam.name) \(leaf.commandLine)", leaf.summary))
            }
        }
        lines.append(contentsOf: renderTable(rows))
        lines.append("")
        lines.append(contentsOf: exitStatusBlock())
        lines.append("")
        lines.append("Run `\(programName) <command> --help` (or `<command> <subcommand> --help`) for scoped usage, options, and examples.")
        return lines.joined(separator: "\n")
    }

    // MARK: Family

    private static func familyHelp(_ fam: CLIFamily) -> String {
        var lines: [String] = []
        lines.append("\(programName) \(fam.name) — \(fam.summary)")
        lines.append("")
        lines.append("usage: \(programName) [--wiki <id>] \(fam.name) <subcommand> [--help]")
        lines.append("")
        lines.append("subcommands:")
        lines.append(
            contentsOf: renderTable(fam.leaves.map { ("\("\(fam.name) \($0.commandLine)")", $0.summary) }))
        let options = fam.allOptions
        if !options.isEmpty {
            lines.append("")
            lines.append("options (across the family; each subcommand accepts its own subset — see its --help):")
            lines.append(contentsOf: renderTable(options.map { ($0.signature, optionSummary($0)) }))
        }
        lines.append("")
        lines.append(contentsOf: exitStatusBlock())
        lines.append("")
        lines.append("Run `\(programName) \(fam.name) <subcommand> --help` for per-subcommand usage and examples.")
        return lines.joined(separator: "\n")
    }

    // MARK: Leaf

    private static func leafHelp(header: String, usagePath: String, leaf: CLILeaf) -> String {
        var lines: [String] = []
        lines.append("\(header) — \(leaf.summary)")
        lines.append("")
        lines.append("usage: \(programName) [--wiki <id>] \(usagePath)")
        for detail in leaf.details {
            lines.append("")
            lines.append(contentsOf: wrap(detail, width: 92, indent: ""))
        }
        if let operations = leaf.operations {
            lines.append("")
            lines.append("operations:")
            lines.append(contentsOf: renderTable(operations.map { ($0.usage, $0.summary) }))
        }
        if !leaf.options.isEmpty {
            lines.append("")
            lines.append("options:")
            lines.append(contentsOf: renderTable(leaf.options.map { ($0.signature, optionSummary($0)) }))
        }
        if !leaf.examples.isEmpty {
            lines.append("")
            lines.append("examples:")
            lines.append(contentsOf: leaf.examples.map { "  \($0)" })
        }
        lines.append("")
        lines.append(contentsOf: exitStatusBlock())
        return lines.joined(separator: "\n")
    }

    // MARK: OKF operation

    private static func okfOperationHelp(family: CLIFamily, leaf: CLILeaf, operation: CLIOperation) -> String {
        var lines: [String] = []
        lines.append("\(programName) \(family.name) okf \(operation.name) — \(operation.summary)")
        lines.append("")
        lines.append("usage: \(programName) [--wiki <id>] \(family.name) okf \(operation.usage)")
        lines.append("")
        lines.append("options:")
        lines.append(contentsOf: renderTable(operation.options.map { ($0.signature, optionSummary($0)) }))
        lines.append("")
        lines.append(contentsOf: wrap(okfOperationsNote, width: 92, indent: ""))
        lines.append("")
        lines.append(contentsOf: exitStatusBlock())
        lines.append("")
        let otherOperations = (leaf.operations ?? []).map(\.name).filter { $0 != operation.name }
        lines.append("Other operations: \(otherOperations.joined(separator: ", ")). Run `\(programName) \(family.name) okf --help` for the overview.")
        return lines.joined(separator: "\n")
    }

    // MARK: Shared blocks + layout

    /// Exit statuses, documented on every help surface (mirrors main.swift).
    private static func exitStatusBlock() -> [String] {
        [
            "exit status:",
            "  0  success",
            "  1  runtime error — the operation failed",
            "  2  usage error — bad arguments; usage goes to stderr",
            "  3  CAS conflict — `page add --expect-head` lost a race; re-read, reapply, retry once",
        ]
    }

    /// `(required)` / `(repeatable)` suffixes for option-table summaries;
    /// skipped when the summary already says it (avoids "repeatable
    /// (repeatable)").
    private static func optionSummary(_ option: CLIOption) -> String {
        var text = option.summary
        if option.required,
            !text.localizedCaseInsensitiveContains("required")
        { text += " (required)" }
        if option.repeated,
            !text.localizedCaseInsensitiveContains("repeatable")
        { text += " (repeatable)" }
        return text
    }

    /// Greedy word wrap. Continuation lines get `indent`.
    private static func wrap(_ text: String, width: Int, indent: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > width, !current.isEmpty {
                lines.append(current)
                current = indent + String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Two-column table. Long left columns wrap under themselves; summaries
    /// wrap in the right column. Fixed widths — agents and pipes read this,
    /// not a TTY.
    private static func renderTable(_ rows: [(String, String)], leftWidth: Int = 40, totalWidth: Int = 96) -> [String] {
        var lines: [String] = []
        let rightWidth = totalWidth - leftWidth
        for (left, right) in rows {
            let leftLines = wrap(left, width: leftWidth - 2, indent: "  ")
            let rightLines = wrap(right, width: rightWidth, indent: "")
            let count = max(leftLines.count, rightLines.count)
            for index in 0..<count {
                let l = index < leftLines.count ? leftLines[index] : ""
                let r = index < rightLines.count ? rightLines[index] : ""
                if r.isEmpty {
                    lines.append("  " + l)
                } else {
                    let padded = l.count < leftWidth ? l + String(repeating: " ", count: leftWidth - l.count) : l
                    lines.append("  " + padded + " " + r)
                }
            }
        }
        return lines
    }
}
