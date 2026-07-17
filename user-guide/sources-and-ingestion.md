# Sources & Ingestion

Sources are the raw material you bring into the wiki — PDFs, web pages, podcast
episodes, markdown notes. The agent reads them and turns them into wiki pages
through **ingestion**. This page covers everything you can do with sources.

---

## What is a source?

A source is any file or fetched document you've added to the wiki. Sources are
stored as-is (verbatim bytes) and can optionally have a **processed markdown**
version (extracted from PDFs, fetched from web pages, etc.).

| Source type | Examples | Has markdown? |
|---|---|---|
| **PDF** | Research papers, reports, ebooks | After extraction (yes) |
| **Web page** | Blog posts, documentation, articles | Yes (fetched and converted) |
| **Markdown** | Notes, Obsidian exports, LogSeq | Yes (the file itself) |
| **Podcast** | Apple Podcasts episodes | If a transcript is available |
| **Image** | PNG, JPEG, screenshots | No (binary embed only) |
| **Other** | CSVs, JSON, code files | No (agent reads raw bytes) |

---

## Adding sources

### Drag and drop

Drag any file from Finder onto the wiki window. A blue accent border confirms
the drop target. Multiple files can be dropped at once. The files are stored
verbatim and appear in the Sources sidebar.

### From a URL

1. Click **Add from URL** in the Sources sidebar header.
2. Paste a URL (or right-click an `https://` link in any page → **Add as Source**).
3. Click **Fetch** — the page is downloaded, share-links are normalized, and
   content is converted from HTML to Markdown.
4. For podcast URLs, the episode page is fetched and any transcript is extracted.

The fetched content lands in Sources with a **Website** or **Apple Podcast**
origin tag.

**Media URLs are byteless.** Paste a **YouTube**, **Vimeo**, **Spotify**,
**SoundCloud**, or **Apple Podcasts** URL and the app recognizes it as web
media: nothing is downloaded — it stores a lightweight source that remembers
the provider and the video/episode id. These sources are first-class (visible,
searchable, and citable), and you embed them as inline players with
`![[source:Name]]`. See [Embeds](pages-and-links.md#embedding-a-youtube-video-or-other-web-media).

### From Zotero

If you use [Zotero](https://www.zotero.org/) for reference management:

1. Configure Zotero in **Settings → Zotero** (API key + library ID).
2. Click **Add from Zotero** in the Sources sidebar.
3. Search your library by title, author, or year.
4. Select an item to see its attachments (PDFs, notes).
5. Toggle which attachments to import.
6. Click **Add Selected**.

Imported sources carry a **Zotero** origin tag with a clickable "View in Zotero"
link that opens the item in the Zotero app.

### Import a folder

Bring in an entire directory of notes:

1. Click **Import Folder** in the Sources sidebar.
2. Click **Choose…** to pick a directory (e.g., an Obsidian vault).
3. Click **Scan Folder** — counts all `.md` and `.pdf` files recursively.
4. Click **Import N Files** to bring them all in.

Frontmatter and `[[wikilinks]]` in imported markdown are preserved as-is. Files
with duplicate names are deduplicated. Per-file errors are collected and shown
if any occur.

---

## The Sources sidebar

The Sources section shows all sources in your wiki:

- **Search bar** — semantic search across source names and content.
- **Status indicators** on each row:
  - ◌ (dashed circle) — **Ready** to ingest (markdown available).
  - ⟳ (spinner) — **Extracting** (PDF-to-markdown in progress) or **Ingesting** (agent is reading it).
  - ✓ (checkmark) — **Ingested** (agent has already processed this source).
- **Multi-select** — ⌘-click or shift-click to select multiple sources.
- **Right-click context menu:**

| Menu item | Description |
|---|---|
| Open | Opens the source in a tab. |
| Open in Background | Opens in a background tab (doesn't switch to it). |
| Open With… | Submenu of external apps for this file type. |
| Add to Bookmarks… | Bookmark the source into a folder. |
| Share | Share the file via the system share sheet. |
| Reveal in Finder | Show the file in Finder. |
| Ingest / Ingest N Sources | Queue for agent processing. |
| Extract Markdown / Extract N Sources | Run PDF-to-markdown extraction. |
| Rename | Change the display name. |
| Delete / Delete N Sources | Remove from the wiki. |

---

## The source detail view

Click a source to open it in the detail pane. What you see depends on the source
type.

### Header metadata

- **File icon** and **display name** (editable).
- **File size** (e.g., "1.2 MB").
- **Added** and **Updated** dates.
- **Origin tags** — clickable links showing where the source came from:
  - 🔗 **Website** — opens the original URL.
  - 📚 **Zotero** — opens the item in Zotero.
  - 🎙️ **Apple Podcast** — opens the episode page.
  - 📁 **Folder** / **File** — local import label.

### Content tabs (for PDFs with extraction)

| Tab | What it shows |
|---|---|
| **Markdown** | Rendered markdown from the extraction. Full wiki-link support. |
| **PDF** | Inline PDF viewer (PDFKit). |
| **Split** | Side-by-side markdown and PDF. Drag the divider to resize. |

For non-PDF sources (web pages, markdown files), the markdown tab shows directly.

### Action buttons

| Button | When it appears | What it does |
|---|---|---|
| **Ingest** | Always | Queues the source for agent processing into wiki pages. |
| **Extract** | Unextracted PDFs | Runs PDF-to-markdown conversion. |
| **Refresh** | Live sources (websites, podcasts) | Re-fetches the source and appends a new content version. |
| **Compare Extractions** | When ≥2 extractions exist | Opens a side-by-side comparison window. |
| **Edit** (⌘E) | Sources with markdown | Opens the processed-markdown editor. |
| **Show in List** | Always | Reveals the source in the sidebar. |
| **Share** | Always | System share sheet. |
| **Reveal in Finder** | Always | Opens Finder to the source file. |

---

## PDF extraction

PDFs need to be converted to markdown before the agent can read them. This is
called **extraction**, and it happens automatically when you ingest a PDF, or you
can trigger it manually.

### Extraction backends

Configure in **Settings → Extraction**:

| Backend | How it works |
|---|---|
| **Local pdf2md** (default) | Bundled VLM model (~2 GB). Runs locally, no API key. Slowest but free and private. |
| **Claude** | Uses Anthropic's API. Fast, high quality. Needs API key. |
| **Gemini** | Uses Google AI. Fast, high quality. Needs API key. |
| **Docling Serve** | Self-hosted Docling instance. Configure base URL. |

Each backend has a **Test Connection** button to verify configuration before use.

### Extraction versions

Each extraction is stored as a separate **version**. This means:

- **Re-extracting** creates a new version without losing the old one.
- **Compare Extractions** shows any two versions side-by-side in the real reader.
- **Set Active** nominates which version the agent uses and which appears in the
  reader.
- **Version-pinned links** (`[[source:Name@v3]]`) lock a quote to a specific
  version, so re-extraction can't break existing citations.

### Extraction status

- **"Extracting…"** appears on the source row and in the source detail while
  pdf2md is running.
- The **Extraction Queue** window (⌘E from the menu bar) shows extraction jobs
  with live progress.
- macOS notifications fire when extraction completes or fails.

---

## Ingestion

**Ingestion** is the core operation: the agent reads sources and writes wiki
pages.

### How to ingest

1. Select one or more sources in the sidebar.
2. Right-click → **Ingest** (or **Ingest N Sources**).
3. A hint appears: *"Ingest queued."*
4. The agent processes each source and writes pages.

### What happens during ingest

- **Small sources** — a single agent pass reads the source and writes pages.
- **Large sources** — a lead agent (Opus) fans out to parallel sub-agents
  (Sonnet) that each digest a portion read-only. The lead agent then decides
  what belongs and writes everything.
- The agent creates **summary pages**, **entity pages**, and **concept pages**,
  cross-references them with `[[wiki links]]`, and updates `index.md` and `log.md`.

### Monitoring ingest

| Where | What you see |
|---|---|
| **Menu bar icon** | Fills in while the agent is working. |
| **Source rows** | Spinner with "Ingesting…" |
| **Agent Queue window** (⌘I) | Live transcript of the agent's tool calls and reasoning. |
| **macOS notification** | Fires on completion or failure. |

### Re-ingesting

If you re-ingest a source that's already been processed, a confirmation appears
listing the sources and warning about potential duplicate pages. This is useful
when:

- The source content has changed (you refreshed a web page).
- You updated the system prompt and want better pages.
- You switched extraction backends and want higher-quality markdown.

---

## The queue system

All extraction and ingestion operations flow through a **persistent queue** that
survives relaunch. This means:

- **Operations keep running** even if you close all windows.
- **Operations are ordered** — you can drag to reorder queued items.
- **Ingestion is serialized** — one job runs at a time globally (a per-provider
  limit of 1 with a single shared provider). A per-wiki invariant additionally
  ensures a wiki is never double-ingested.
- **Extraction concurrency depends on the backend** — local pdf2md runs one
  extraction at a time; remote backends (Claude, Gemini, Docling Serve) allow
  up to 2 concurrent extractions.
- **You can pause, resume, halt, cancel, and retry** from the activity windows.
- **Crash recovery** — if the app crashes, in-flight items are re-queued on next
  launch.

### Activity windows

Open from the menu bar or keyboard:

| Window | Shortcut | What it shows |
|---|---|---|
| **Agent Queue** | ⌘I | Ingestion and lint jobs. Live agent transcript in the detail pane. |
| **Extraction Queue** | ⌘E | PDF-to-markdown jobs. Progress text in the detail pane. |

Both windows show:
- **Active** section — currently running and queued items (drag to reorder).
- **Recent** section — last 30 completed/failed/cancelled items.
- **Per-item controls** — Cancel (running/queued), Retry (failed/cancelled).
- **Toolbar** — Pause/Resume, Stop All.
