# Organizing & Managing

This page covers everything related to organizing your knowledge base and
managing the app: bookmarks, search, navigation, multiple wikis, settings, the
activity queue, and notifications.

---

## Bookmarks

Bookmarks are your personal table of contents — a folder tree of shortcuts to
pages, sources, and chats you want to reach quickly.

### The Bookmarks sidebar

Switch to the **Bookmarks** section (🔖 icon). You see a native outline view
with:
- **Folders** — organize bookmarks hierarchically. Nested subfolders supported.
- **Page references** — shortcuts to wiki pages.
- **Source references** — shortcuts to sources.
- **Chat references** — shortcuts to chat conversations.
- **Stale refs** — if a target was deleted, a ⚠️ warning icon appears (the node
  is preserved, not auto-deleted).

### Adding bookmarks

| Method | How |
|---|---|
| **From the omnibox** | Hover on any page/source/chat → **+** button appears → click to add to bookmarks root. |
| **From Pages/Sources lists** | Multi-select rows → right-click → **Add to Bookmarks…** → pick or create a destination folder. |
| **From a wiki link** | Right-click a resolved `[[link]]` in any reader → **Add Bookmark…** → pick a folder. |
| **From Bookmarks header** | Click **+** → New Folder / Add Page… / Add Source… → search picker. |
| **Drag and drop** | Drag a wiki-link from the page body, or drag the omnibox **+** button onto the bookmarks tree. |

### Organizing bookmarks

- **Drag to reorder** — within the same parent or between folders. Multi-select
  drag supported.
- **Right-click context menu:**
  - Open / Open in Background / Open With (single items).
  - Edit… — rename the folder or ref, view target info and timestamps.
  - Add Page… / Add Source… / New Subfolder (folders only).
  - Delete (batch supported).
- **Search** — filters by resolved titles. Ancestor folders auto-expand so
  nested hits are visible.

### The BookmarkTargetPickerSheet

When you bookmark from the Pages or Sources list, a sheet asks **where** to file
it:
- Shows your folder tree with radio-style selection.
- **Create folder** inline — type a name and add a new destination on the spot.
- Root ("Bookmarks") is available for top-level items.
- Header shows count: *"Add 3 Pages to Bookmarks."*

### Use case: ask the agent to build an outline, then open it in Obsidian

You don't have to file bookmarks by hand. Because the agent can create and
organize bookmarks the same way you can, you can hand it a curation task in
Chat:

> *"Create a bookmark folder called **Reading List** with subfolders for each
> author, and file every source and its summary page under the right author.
> Add a **Key Chats** folder with the conversations where we worked out the
> methodology."*

The agent builds the folder tree and files pages, sources, and chats into it.
Now the payoff: the **File Provider mount** (the optional read-only folder the
wiki exposes in Finder) projects that same bookmark tree to disk under a
top-level `bookmarks/` folder —

- Bookmark **folders** become real folders.
- **Page** and **chat** bookmarks become `.md` files (chats render as a
  transcript).
- **Source** bookmarks appear as the original file.
- `[[Wiki links]]` inside the pages are rewritten to **relative paths**, so they
  resolve *within* the exported folder layout.

That last point is what makes the tree a working Obsidian vault, not a flat
dump. Point Obsidian (or any Markdown editor) at the wiki's mount folder — or
just the `bookmarks/` subfolder — and you get the exact outline the agent built,
with clickable links between pages. The agent organizes; you read the result in
your editor of choice.

> The mount is **read-only** — edits happen in the app or through the agent, and
> the folder re-projects automatically. See
> [multiple wikis](#multiple-wikis) for enabling a per-wiki mount.

---

## Search

### Sidebar search (Pages & Sources)

Each sidebar section has a search bar at the top. Typing triggers **semantic
search** — meaning-based ranking, not just text matching:
- Searching "machine learning" finds pages about "deep learning" or "neural networks."
- Results are ranked by relevance using local embeddings.
- FTS5 (full-text search) is fused with semantic similarity for a hybrid ranking.

### Omnibox search (⌘L)

The address bar doubles as a global search:
1. Press **⌘L** to focus.
2. Type — results appear in a dropdown below.
3. Suggestions include **pages, sources, chats, and bookmarks**.
4. **Arrow keys** navigate; **Enter** opens; **Escape** dismisses.

### Chats search

The Chats sidebar has its own search bar with hybrid full-text + semantic search
across chat titles and content.

---

## Navigation

| Action | Shortcut / Method |
|---|---|
| Go back | ⌘[ or Back arrow in toolbar |
| Go forward | ⌘] or Forward arrow in toolbar |
| Go home | Home button in toolbar (if configured) |
| Focus address bar | ⌘L |
| Find on page | ⌘F |
| Switch to tab N | ⌘1–⌘9 |
| Reopen closed tab | ⌘⇧T |
| Close tab | ⌘W |
| Follow wiki link | Click `[[link]]` in any reader |
| Show in List | "Show in List" button in any detail header |

---

## Multiple wikis

You can have **many wikis** — each is a self-contained knowledge base with its
own pages, sources, chats, and agent.

### Creating wikis

- **Wiki switcher** (toolbar) → **New Wiki…** → name it → Create.
- Each wiki gets its own SQLite database and (optionally) its own File Provider
  mount folder.

### Switching between wikis

| Action | What happens |
|---|---|
| **Click** a wiki in the switcher | Opens it in a **new window** (Safari-style). Each wiki gets its own window. |
| **Option-click** a wiki | Switches the **current window** to that wiki in place (no new window). |

### Wiki operations

From the **wiki switcher** menu:

| Operation | Description |
|---|---|
| **New Wiki…** | Create a new knowledge base. |
| **Rename [name]…** | Change the display name. |
| **Export [name]…** | Save a SQLite backup of the entire wiki. |
| **Delete [name]…** | Permanently remove the wiki and all its data. |
| **Import Wiki Backup…** | Restore from a `.sqlite` export. Prompts for a display name. |

### Multi-window

- Each wiki opens in its own window with its own session.
- Two windows over the **same** wiki share one underlying session (one database,
  one event bus) — edits in one window are visible in the other.
- A long ingest in wiki A's window does **not** block a query in wiki B's window
  (per-wiki isolation).

---

## Settings

Open with **⌘,** or **menu bar → Settings…**

### About

- App icon, name, version, build, and git SHA.
- Opens by default when you first visit Settings.

### Agents

Configure the AI providers that power the agent:

- **Provider list** — add, remove, enable/disable, mark default.
  - Each provider: label, launch command, environment variables, API key
    (Keychain-backed), model selection.
  - **Test Connection** verifies the provider works.
- **Ingestion stages** — route different stages (Planner, Executor, Finalizer)
  to different providers/models. Use a strong model for planning, a cheaper one
  for bulk reading.
- **Permission mode** — Bypass (autonomous) or Always Ask (approval-gated).
- **Models** — auto-captured from the first chat; you can't manually refresh
  (they're discovered live).

### Extraction

Configure PDF-to-markdown conversion:

- **Backend picker** — Local pdf2md, Claude, Gemini, or Docling Serve.
- **Per-backend config** — API keys (Keychain), model name, base URL.
- **Test Connection** per backend — live verification.
- Settings are locked (grayed out) while an extraction is running.

### Zotero

Connect your Zotero reference library:

- **API Key** — Keychain-backed.
- **Library ID** — your Zotero library/group ID.
- **Local library folder** — override the default Zotero data directory.
- **Test Connection** — verifies credentials.

### General

- **Ask before quitting** (default on) — catches ⌘Q, Apple menu Quit, Dock Quit,
  and shutdown. You can still quit via the dialog or by disabling this.

---

## The activity queue

All extraction and ingestion operations flow through a **persistent queue**.

### What the queue does for you

- **Survives relaunch** — in-flight items are re-queued after a crash or restart.
- **Runs in the background** — operations continue even with no window open.
- **Concurrency management** — one ingest per wiki at a time; extractions
  parallelize across different files.
- **Ordering** — drag to reorder queued items.

### Queue controls

| Control | Where | What it does |
|---|---|---|
| **Pause / Resume** | Activity window toolbar | Stops dispatching new items; resume restarts. Persists across relaunch. |
| **Stop All** | Activity window toolbar | Cancels all in-flight items in that queue (re-queued). |
| **Cancel** | Per-item button | Cancels a single running or queued item. |
| **Retry** | Per-item button | Re-enqueues a failed or cancelled item. |

### Activity windows

| Window | Shortcut | Contents |
|---|---|---|
| **Agent Queue** | ⌘I | Ingestion + lint jobs. Detail pane shows live agent transcript. |
| **Extraction Queue** | ⌘E | PDF-to-markdown jobs. Detail pane shows progress text. |

Both show:
- **Active** section (running + queued, drag-reorderable).
- **Recent** section (last 30 terminal items).
- Per-item status: spinner (running), clock (queued), ✓ (completed), ⚠️ (failed), ✕ (cancelled).
- Source filenames + wiki name + relative time.
- Context menu: Copy Transcript, Cancel, Retry, Copy Error.

---

## Notifications

| Type | When | What you see |
|---|---|---|
| **macOS notification** | Extraction, ingestion, or lint reaches a terminal state | Banner with title + summary (e.g., "Ingestion complete — 3 files processed"). Appears as a banner when the app is in the background; silent in Notification Center when frontmost. |
| **Hint popover** | You queue an operation | Brief 2.5s popover anchored to the menu bar icon: "Ingest queued." |
| **Menu bar tooltip** | Agent state changes | "Idle" / "Processing (N active, M queued)" / "Paused" / "Attention needed" |
| **Menu bar icon** | Agent state changes | Fills in (books.vertical.fill) while working; outline when idle. |

Cancelled items do **not** trigger notifications (user-initiated, not actionable).

---

## The change log

The change log is the agent's **operation history** — an append-only `log.md`
that records every ingest, lint run, and significant event.

**Access:**
- Toggle the **change log sidebar** from the toolbar (sidebar.trailing icon).
- Or open the Change Log tab directly.

**What you see:**
- Formatted Markdown rendered in the reader.
- Each entry is timestamped and describes what the agent did.
- Wiki links in the log are clickable — navigate to referenced pages.

**Empty state:** "No Log Entries — Agent runs will append their notes here."

---

## The system prompt

The system prompt (`CLAUDE.md` / `AGENTS.md`) is the instruction set the agent
reads at the start of every run. It tells the agent how to format pages, when to
create links, what conventions to follow, etc.

**Access:** Menu bar → **Maintenance** → **Agent Instructions**, or open the
System Prompt tab.

**Editing:**
- Click **Edit** (or ⌘E) to enter edit mode.
- Save with ⌘S. Changes take effect on the next agent run.
- The header explains: *"The agent reads this each run."*

Customizing the system prompt is how you control the agent's behavior — e.g.,
asking it to use a specific citation style, create pages of a certain length, or
focus on particular themes.
