# Repository Tracking

## Direction

A wiki can **track git repositories**. You add one by remote URL and the app
clones it into its own storage. When you ask, it checks the remote for new
commits; when you ask again, Claude reads what changed and revises the wiki pages
about that repository. The Query conversation becomes repo-aware, so a question
can be answered from the wiki *and* from the tracked source.

**Nothing here runs on its own.** No timer, no unattended agent run. A repo pass
is an Opus run with a Sonnet fan-out, and a background loop that starts one
overnight spends real money on work nobody asked for. Learning about drift a
click late is a far smaller problem, so both steps — check, then update — are
explicit.

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
2. **Manual refresh, manual update.** No poll loop and no unattended agent runs.
   "Check for New Commits" fetches (network only, zero tokens) and updates the
   drift badges; "Update Wiki Now" is the only thing that starts a pass. Adding a
   repo clones it and stops there — tracking a repo says *watch this*, not *spend
   on it right now*. There is consequently no `auto_ingest` column and no
   automatic-update toggle: with nothing unattended to govern, a switch wired to
   nothing is worse than no switch.
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
  last_ingested_commit, last_fetched_at, created_at, updated_at, version`, with
  `remote_url` UNIQUE so the same repository can't be tracked twice in one wiki. Not folded into `changeToken()` (decision #4); the sidebar refreshes
  off the existing Darwin-notification path in `WikiChangeBridge`.
- **Pure core** (`WikiFSCore`, all unit-tested): `TrackedRepo`, `GitRemoteURL`
  (what we accept and what we hand `git clone`), `GitCommandPlan` (every git argv),
  `RepoCheckoutLocation` (ULID-keyed paths), `RepoSyncPlan` (the
  up-to-date / initial / incremental decision plus the model tier), and
  `RepoStateSnapshot` (the staged `REPO_STATE.md`).
- **`GitRunner`** (app target) executes `GitCommandPlan` argv — the same
  what/how split `AgentLauncher` uses for `claude`. It reads both pipes before
  waiting, so a large file list can't deadlock against a full pipe buffer.

### Private repositories go through `gh`

A GUI-spawned `git` has no terminal and no useful credential state, so a private
repo dies at clone with `could not read Username`. The user is already
authenticated — `gh` holds a token — so every git invocation is prefixed with

```text
-c credential.https://github.com.helper=
-c credential.https://github.com.helper=!'<path to gh>' auth git-credential
```

which is exactly the pair `gh auth setup-git` would install. Passing it as `-c`
flags rather than writing it means **the app never edits the user's gitconfig**:
the arrangement lives and dies with our own processes. The empty first `helper=`
resets any inherited chain for that host, so a stale osxkeychain entry can't
answer first with a dead token. Because the config is scoped to
`credential.https://github.com.helper`, it is inert for every other host and can
be applied unconditionally instead of threading each command's remote down to the
plan; with no `gh` installed it collapses to `[]` and the user's own helpers are
left alone.

`GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS=/usr/bin/false` remain as the backstop
for hosts the helper doesn't cover — a repo that still needs credentials fails
fast instead of hanging. Git's own auth errors are accurate but unactionable in a
GUI ("could not read Username" tells you nothing to *do*), so `GitRunner.Failure`
appends the one command that usually fixes it: `gh auth status`, then
`gh auth login`. It also names the trap that "Repository not found" is what GitHub
returns for a private repo your token can't see.
- **`RepoTracker`** (`@MainActor @Observable`) owns the clone/fetch operations,
  the per-repo activity and error state, and the FIFO of repos waiting to be
  ingested. It has no timer: `fetchAll()` and `requestIngest(_:)` are both driven
  by a click.
- **UI**: a "Repositories" sidebar section (`RepoRow` with a sync badge) whose
  header carries "Check for New Commits" and "Track a Repository…", a
  `AddRepositorySheet` modeled on `AddFromURLSheet`, and a `RepoDetailView`
  modeled on `IngestedFileDetailView` (Update Wiki Now / Check for New Commits).
  One toolbar "Add Source" menu covers both "Add from URL…" and "Track a
  Repository…", so the drag-zone stays sparse and there is an entry point when
  both sections are still empty.

### The serialization rule

Even with every run user-initiated, the queue is still needed. `AgentLauncher` is
app-wide and refuses to start a second run, so an Update requested while another
run is going wouldn't queue — it would silently vanish. The tracker drains only
when the launcher is idle **and** no interactive Query session is open (an agent
run that grabs the editor lock mid-conversation is its own kind of surprise), and
`ContentView` nudges it from `onChange(of: launcher.isRunning)` when a run ends.
If a queued pass turns out not to start — missing checkout, git failure, already
up to date — the drain keeps going rather than waiting for a completion that will
never arrive, because with no poll loop nothing else would unstick it.

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
number the row can't stand behind is worse than a plain word. It is also only as
fresh as your last check — nothing fetches on a timer, so the badge answers "what
did I know when I last looked", which is why the check action sits right in the
section header. In-flight work ("Cloning…", "Checking…", "Queued", "Updating…")
wins over drift, because a state that's about to change is less useful than what
is happening now.

A failed clone **keeps the row**, carrying the error, so a bad URL or a missing
credential leaves you with a repo you can retry rather than a sheet that appears
to have done nothing.

## Accepted limitations

- Drift is only as current as your last check. A repo can be days behind and the
  sidebar will happily show a green check until you press the refresh button.
  That is the deliberate trade for never spending model budget unprompted; if it
  ever becomes annoying, the cheap half (a fetch-only poll, still with no
  automatic agent run) is the thing to add back — `RepoTracker.fetchAll()` is
  already the right entry point for it.
- Private GitHub repos need `gh` installed and logged in. Non-GitHub hosts fall
  back to whatever credential helper or SSH agent the user already has; the app
  never prompts for, stores, or sees a credential itself.
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
