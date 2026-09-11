# Chat tool-call summary

Status: shipped. Normal chat transcripts are concise by default. Each contiguous
run of tool calls becomes one expandable **Tool activity** row, and the known
ACP skill-description budget warning no longer appears in human-facing chat
output. Diagnostics and the Activity surfaces stay detailed.

## Modes

The user picks the mode in Settings → Appearance → Chat. The choice persists.

| Mode | Behavior |
| --- | --- |
| **Summary** (default) | Each maximal contiguous run of tool calls in one turn collapses into a single expandable row. Expanding it shows every original call. |
| **Detailed** | One expandable row per tool call. This is the historical display. |
| **Hidden** | No tool-call rows. This is the historical Hide option. |

The preference is the typed enum `ChatToolCallDisplayMode`, stored under the
single key `chat.toolCallDisplayMode`. Missing and invalid raw values resolve to
`summary`. The legacy Boolean key `chat.hideToolCalls` migrates once at launch
(`ChatToolCallDisplayPreference.migrate(in:)`, called from `WikiFSApp.init()`
before any view reads the new key): `true` becomes `hidden`; `false` or absent
becomes `summary`; an existing new-key value always wins. The legacy key stays
on disk as an orphaned compatibility value and is never read again.

## Grouping

The grouping lives in `ChatTranscriptPresentationProjection`, a pure app-only
projection layered over the canonical `ChatDisplayProjection` output. Canonical
projection remains one row per durable item; it is what the Activity window,
Show Full Activity, and diagnostics render. Grouping never mutates canonical
data, durable rows, the SQLite store, or the XPC contract.

A run is a maximal sequence of adjacent tool-call rows inside one section.
A message, reasoning row, notice, failure row, unattributed section, or turn
boundary ends a run. Runs never cross turns.

Group identity is `ChatToolCallGroupID`, derived from the run's first tool-call
ID (the host). When a live run grows, the projection re-emits the same identity
with more children, so the render planner produces one `replace` command and the
DOM element — including its `<details>` open state, preserved by
`replaceChatRow` — survives. Nested child elements carry `data-tool-call-id`,
never the root `data-row-id` protocol.

## Summary row content

The collapsed row shows the stable label **Tool activity**, a deterministic
category phrase (for example "3 commands, 5 files read, and 2 searches"), and a
state cue that pairs a symbol with text (`◌ Running`, `✓ Completed`,
`⚠ 2 failed`). An active group that already contains failures reports the
failure count in its state. The accessibility label includes the total tool-call
count, the failure count, and the state.

Disclosure is keyboard operable: the `<summary>` is a native focus target and
Return toggles it natively. A delegated keydown handler scoped to tool-group
summaries also maps unmodified Space to the toggle (suppressing the page
scroll that bare Space would otherwise perform), so both keys flip the row
exactly once; a hosted test pins each key's behavior with synthesized events.

Categories are counted in this fixed order: files edited, edit operations,
shell commands, files read, read operations, searches, other tool calls.
Classification reads only the normalized tool name and the call's input
descriptor. Tool output is never read for classification, so arbitrary command
output cannot change a summary. Recognized names: `Bash`/`execute` (shell),
`Read`, `Edit`/`Write`, `Grep`/`Glob`/`search`/`WebSearch` (searches). Unknown
and legacy names count as other tool calls.

### Single-path grammar

A read or edit descriptor counts as one file only when it satisfies this
mechanically decidable grammar (`ChatToolCallSinglePathGrammar`):

1. Trim Unicode whitespace. Remove exactly one balanced pair of matching ASCII
   single or double quotes, then trim whitespace once more inside the quotes.
   An empty result is ambiguous.
2. Reject on: C0 or DEL control characters; line breaks; `://`; Windows drive
   or UNC prefixes; backslashes; percent escapes; a leading `-`; a trailing
   `/`; repeated `//`; colon; semicolon; pipe; ampersand; backtick; dollar;
   angle brackets; parentheses; braces; brackets; `*`; `?`; comma- or
   newline-separated locations; any surviving (unbalanced) quote.
3. Accept as a path: `/`-absolute, `~/`, `./`, `../`, or any relative form
   containing at least one `/`. Spaces are allowed in accepted path forms, so
   `docs/my notes.md` and `./my notes` are paths, while `draft notes` and
   `Read package manifest` are ambiguous.
4. Otherwise accept a bare filename only when its final extension is in the
   fixed case-insensitive allowlist (`md`, `markdown`, `txt`, `json`, `jsonc`,
   `yaml`, `yml`, `toml`, `swift`, `m`, `mm`, `h`, `c`, `cc`, `cpp`, `rs`,
   `go`, `py`, `rb`, `js`, `jsx`, `ts`, `tsx`, `css`, `html`, `xml`, `sql`,
   `sh`, `zsh`, `fish`, `csv`, `tsv`, `pdf`, `docx`, `png`, `jpg`, `jpeg`,
   `gif`, `webp`, `svg`). `archive.tar.gz` fails because its final extension
   `gz` is not listed. `Makefile`, `.env`, and unknown extensions stay
   ambiguous. Renderer-package diagram extensions are deliberately absent:
   the renderer source-neutrality contracts keep those format names out of
   production Swift, so files carrying them count as ambiguous operations.

Accepted paths normalize only by collapsing internal `/./` components and
dropping a trailing `/.`. `..` is never resolved, `~` never expanded, case
never changed, escapes never decoded, and the file system is never consulted.
Grammar-approved paths deduplicate by exact normalized string; every ambiguous
or missing descriptor counts as one distinct operation per tool call.

## Known-warning removal

The one known preamble is removed from human-facing output by the shared,
typed helper `AgentPresentationPreamble` (WikiFSCore). Its two policies:

- `streamingPrefixAware` — hides the complete warning and a still-streaming
  proper prefix of it, so a warning-only reply never flashes. Used only for
  normal-chat assistant rows whose content state is `.streaming`.
- `completeOnly` — removes only the complete warning: a line that starts with
  `Warning: Skill descriptions were shortened to fit the 2% skills context
  budget.` The warning line and the blank lines after it go; substantive text
  stays. A final text that is only a proper prefix of the warning is
  preserved. Used for final normal-chat rows, `ChatTranscriptRenderer`
  (File Provider Markdown and `wikictl chat get` exports), `MessageSummarizer`
  inputs, and cached outline summaries.

Unrelated `Warning:` lines are always content and are never removed. The old
broad leading-`Warning:` strip in `MessageSummarizer` is gone; a stale cached
summary cannot reintroduce the warning into chat outlines because cached
summaries are sanitized with `completeOnly` before use, falling back to the
cleaned assistant row text.

## Diagnostic exclusions

Neither policy touches canonical persisted events, redacted diagnostics, the
full debug trace, the Activity window, or Show Full Activity. Those surfaces
render the canonical transcript and keep every tool call and every warning
byte.

## Testing

Pure unit tests cover mode resolution, migration, grouping boundaries, stable
identity, the grammar, count labels, and both warning policies. App
integration tests cover presentation wiring and Activity exclusions. Hosted
WebKit tests cover markup, disclosure persistence across live replacement,
keyboard disclosure, bounded scrolling, and both appearances. A documentation
contract test pins this record, the PLAN.md index, the user guide, and a
completion record. The cited large local chat (28 tool calls in one run) is
mirrored by a synthetic fixture; the real chat is used only for manual
validation because private wiki data never enters the repository.
