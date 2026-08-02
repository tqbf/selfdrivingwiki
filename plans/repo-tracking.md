# Repository Tracking

## Direction

A wiki can **track git repositories**. You add one by remote URL; the app clones
it into its own storage, watches it, and when new commits land Claude reads what
changed and revises the wiki pages about that repository. The Query conversation
becomes repo-aware, so a question can be answered from the wiki *and* from the
tracked source.

This is the first source in the wiki that is **remote, mutable, and on disk**.
Every other source is verbatim immutable bytes in SQLite: staged once, ingested
once, never re-read (`ingested_files`). A repository is the opposite, and the two
facts that carry the difference are `head_commit` (what upstream has) and
`last_ingested_commit` (what the wiki has actually been told about). The gap
between them *is* the work queue.

**Prior art note.** This was asked for "like `jvanderberg/wikimemory`". That
project has no repository tracking — its "repository" is the D1 data-access layer,
its doc types are `system|project|topic|source|note`, and it states that
source-specific importers are deliberately not built in. Its sibling `llmwiki`
has none either. What carried over is the *shape* both projects share with this
one: a tracked entity with provenance, mutated only through an audited CLI, with
the LLM doing all synthesis.

## Locked decisions

1. **Clone-only.** Every tracked repo is app-owned, cloned under
   `~/Library/Application Support/WikiFS/repos/<wikiULID>/<repoULID>/`. The app
   never points at a checkout you are working in, and never writes to any
   checkout other than syncing its own.
2. **Auto-fetch + auto-ingest.** A 15-minute poll fetches; a repo that drifted and
   has `auto_ingest` on is queued for an unattended agent pass.
3. **One repo-aware Query chat**, not a per-repo conversation surface.
4. **No File Provider projection.** Repos are app + agent state. The mount keeps
   its exact shape — no new containers, no `signalChange` changes, and no
   `changeToken()` fold (a repo must not move the mount's sync anchor).
5. **The agent owns the watermark.** The app writes `head_commit`; only the agent
   writes `last_ingested_commit`, via `wikictl repo mark-ingested`, at the end of
   a pass that actually wrote pages. The app *proposes* a commit range; the agent
   *confirms* what it covered, so an interrupted run leaves the watermark behind
   and the next pass re-covers the gap.

## App Shape

- **`tracked_repos` (schema v6)** — `id, name, remote_url, branch, head_commit,
  last_ingested_commit, last_fetched_at, auto_ingest, created_at, updated_at,
  version`, with `remote_url` UNIQUE so the same repository can't be tracked twice
  in one wiki. Not folded into `changeToken()` (decision #4); the sidebar refreshes
  off the existing Darwin-notification path in `WikiChangeBridge`.
- **Pure core** (`WikiFSCore`, all unit-tested): `TrackedRepo`, `GitRemoteURL`
  (what we accept and what we hand `git clone`), `GitCommandPlan` (every git argv),
  `RepoCheckoutLocation` (ULID-keyed paths), `RepoSyncPlan` (the
  up-to-date / initial / incremental decision plus the model tier), and
  `RepoStateSnapshot` (the staged `REPO_STATE.md`).
- **`GitRunner`** (app target) executes `GitCommandPlan` argv — the same
  what/how split `AgentLauncher` uses for `claude`. It runs git with
  `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS=/usr/bin/false` so a repo needing
  credentials fails fast and visibly instead of hanging a GUI-spawned process on
  an invisible prompt, and it reads both pipes before waiting so a large file list
  can't deadlock against a full pipe buffer.
- **`RepoTracker`** (`@MainActor @Observable`) owns the poll loop, the per-repo
  activity/error state, the global auto-update switch, and the FIFO of repos
  waiting to be ingested. Fetching and ingesting are deliberately separate loops:
  fetching is cheap and frequent, ingesting spends model budget and writes to the
  wiki.
- **UI**: a "Repositories" sidebar section (`RepoRow` with a sync badge), a
  `AddRepositorySheet` modeled on `AddFromURLSheet`, and a `RepoDetailView`
  modeled on `IngestedFileDetailView` (Update Wiki Now / Fetch Now / an
  auto-update switch). One toolbar "Add Source" menu now covers both "Add from
  URL…" and "Track a Repository…", so the drag-zone stays sparse and there is an
  entry point when both sections are still empty.

### The serialization rule

`AgentLauncher` is app-wide and refuses to start a second run. An unattended
ingest that fired at the wrong moment wouldn't queue — it would silently vanish,
or worse, land mid-conversation and take the editor lock out from under someone
talking to the wiki. So the tracker drains its queue only when the launcher is
idle **and** no interactive Query session is open, and `ContentView` nudges it
from `onChange(of: launcher.isRunning)` when a run ends.

## Agent Session

A repo pass is a normal one-shot operation — `WikiOperation.repoIngest`, kind
`.repo`:

```text
claude -p <repo prompt> --model opus --output-format stream-json --verbose \
  --include-partial-messages --append-system-prompt <schema> \
  --dangerously-skip-permissions [--agents <repo-reader JSON>]
```

Two state documents are staged into the run's scratch dir: `WIKI_STATE.md` (what
pages exist to cross-link and revise) and `REPO_STATE.md` (head commit, initial
vs incremental, the commits in range, the diff stat, the files that matter, the
checkout path). Both exist for the same reason: the app already knows all of it,
so the agent's turns should go into reading code, not re-deriving state.

Tiering follows `IngestPlan`'s philosophy exactly — Opus is always the curator and
the writer; Sonnet `repo-reader` workers exist only to read volume. The tier
decides whether there is a fan-out, never who writes. A repo under 25 tracked
files, or a diff under 10 changed files, is a single Opus pass; anything larger
fans out to 2–19 `repo-reader` workers with `["Bash","Read","Grep","Glob"]` and no
`wikictl`.

Two rules are specific to code as a source:

- **The checkout is read-only, and saying so is load-bearing.** Unlike the mount,
  which rejects writes by design, a checkout is an ordinary directory where a
  write would succeed — so the prompt explicitly forbids writing files there and
  forbids every mutating git command.
- **Provenance carries the commit**: `[^id]: repo owner/name@<short-sha>,
  path/to/File.ext:120-160`. A repo moves, so a path without a commit stops being
  checkable after the next sync.

`wikictl` gains a deliberately small repo surface — `repo list [--json]`,
`repo get --name owner/repo`, and `repo mark-ingested --name owner/repo --commit
<sha>`, plus `log append --kind repo`. There is no `add`/`remove`: adding a repo
means cloning it over the network into app-managed storage, which is the app's
job, and keeping it out of the CLI is what stops an agent run from quietly
expanding what the wiki tracks.

## UI Notes

The sidebar badge says only what the app actually knows. It shows "Changes", not
"12 behind": the tracker stores a head and a watermark, not a commit count, and a
number the row can't stand behind is worse than a plain word. In-flight work
("Cloning…", "Checking…", "Queued", "Updating…") wins over drift, because a state
that's about to change is less useful than what is happening now.

A failed clone **keeps the row**, carrying the error, so a bad URL or a missing
credential leaves you with a repo you can retry rather than a sheet that appears
to have done nothing.

## Accepted limitations

- Auto-ingest spends real model budget without a click. Mitigations: the
  15-minute poll, per-repo and global toggles, one run at a time, and never during
  a live chat.
- Private repos work only if the existing git credential helper or SSH agent
  already authenticates them; the app never prompts for or stores credentials.
- `--filter=blob:none` partial clones need network access the first time an old
  blob is materialized.
- A force-push invalidates the commit range; `RepoSyncPlan` detects it with
  `git merge-base --is-ancestor` and falls back to a full re-read.
- `SystemPrompt.defaultBody` gained the Repo workflow, but the singleton is only
  *seeded* at migration v2→3 — **existing wikis keep their old instructions**.
  This is survivable because every load-bearing repo rule lives in the `-p` prompt
  (`WikiOperation.repoIngestPrompt`), which every run gets regardless.
- Gates stay structural (pages written, watermark advanced), never content
  assertions — the agent is non-deterministic (`plans/llm-wiki.md`).

**Skills per phase (per `CLAUDE.md`):** `swiftui-pro` and `macos-design` before
and after the UI work (they produced the single "Add Source" toolbar menu instead
of a third top-level button, the honest badge vocabulary, and the accessibility
label on the icon-only status glyph); `typography-designer` was satisfied by
reusing the existing scale — `.largeTitle` bold titles, `.callout` secondary
status, `.caption` metadata with monospaced commit shas.
