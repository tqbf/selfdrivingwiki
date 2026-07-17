# Getting Started

This guide walks you through setting up Self-Driving Wiki from scratch: creating
your first wiki, configuring the agent, adding sources, and running your first
ingest.

---

## 1. Launch the app

Open **Self Driving Wiki** from `/Applications` (or wherever you installed it).
On first launch you'll see a welcome screen with options to create a wiki or
import a backup.

## 2. Create your first wiki

1. Click **New Wiki…** (or use the wiki switcher in the toolbar → **New Wiki…**).
2. Enter a name — e.g., "Machine Learning Notes" or "Q3 Planning."
3. Click **Create**.

The wiki opens with a seeded **Home** page. You're now in the main window.

## 3. Set up the agent

The agent needs a configured AI provider to ingest sources and answer questions.

1. Open **Settings** (⌘, or menu bar → **Settings…**).
2. Go to the **Agents** tab.
3. You'll see the default provider. Edit it or add a new one:
   - **Label** — a name you'll recognize (e.g., "Claude").
   - **Command** — the shell command to launch the agent (e.g., `claude`).
   - **API Key** — stored securely in Keychain.
   - **Model** — which model to use (auto-detected from the first chat, or enter manually).
4. Click **Test Connection** to verify it works.
5. Set the **Permission Mode**:
   - **Bypass** — the agent acts without asking (faster, more autonomous).
   - **Always Ask** — the agent requests your approval before each write (safer, more controlled).

See [Organizing & Managing → Settings](organizing-and-managing.md#settings) for
full details on each settings tab.

## 4. Add your first sources

Sources are the raw material the agent will turn into wiki pages. There are
several ways to add them:

| Method | How |
|---|---|
| **Drag and drop** | Drag a file (PDF, markdown, text) from Finder directly onto the wiki window. A blue border appears as you hover. |
| **From a URL** | Click **Add from URL** in the Sources sidebar (or toolbar), paste a web link, and click **Fetch**. The page is downloaded and converted to markdown. |
| **From Zotero** | Click **Add from Zotero** in the Sources sidebar. Search your Zotero library, select attachments, and import them. (Requires Zotero setup in Settings.) |
| **Import a folder** | Click **Import Folder** to bring in an entire directory of `.md` files (e.g., an Obsidian vault or a folder of notes). |
| **Right-click a link** | While reading a page, right-click any `https://` link and choose **Add as Source**. |

Sources appear in the **Sources** section of the sidebar.

> **PDFs need extraction first.** If you add a PDF, the app runs a PDF-to-markdown
> conversion (extraction) before the agent can read it. You can configure the
> extraction backend in Settings → Extraction. See
> [Sources & Ingestion](sources-and-ingestion.md) for details.

## 5. Run your first ingest

**Ingest** is the operation where the agent reads sources and writes wiki pages.

1. Go to the **Sources** section in the sidebar.
2. Select one or more sources (⌘-click for multi-select).
3. Right-click → **Ingest** (or **Ingest N Sources**).
4. A transient hint appears: *"Ingest queued."*
5. The menu bar icon fills in to show the agent is working.

The agent reads each source, extracts key information, and writes pages with
cross-references. For large PDFs, it fans out to parallel sub-agents to digest
the bulk, then a lead agent decides what to include.

**Monitor progress:**
- The **menu bar icon** fills in while the agent is working.
- Open the **Agent Queue** window (⌘I) to see a live transcript of what the agent is doing.
- Source rows in the sidebar show a spinner ("Ingesting…") while in progress.

When ingest completes, new pages appear in the **Pages** sidebar, and a macOS
notification tells you the result.

## 6. Explore the generated pages

1. Switch to the **Pages** section in the sidebar.
2. Click any page to open it in a tab.
3. Pages render as formatted Markdown with clickable wiki links (`[[Like This]]`).
4. Click a wiki link to navigate to the linked page (it opens in a new tab).
5. Use the **outline** toggle (sidebar.right icon in the page header) to jump to sections.

## 7. Ask your first question

1. Switch to the **Chats** section in the sidebar.
2. Click the **+** button to start a new chat.
3. Type a question in the composer at the bottom — e.g., *"Summarize the key findings from the papers I just ingested."*
4. Press **⌘⏎** (or click the green send button).
5. The agent streams its response. If it wants to modify the wiki, it asks for your approval (in Always Ask mode).

See [Chatting with the Agent](chat.md) for the full chat experience.

---

## Next steps

- [**Interface Tour**](interface.md) — Learn the window layout and navigation.
- [**Pages & Links**](pages-and-links.md) — Master wiki links and the page reader.
- [**Sources & Ingestion**](sources-and-ingestion.md) — Go deep on extraction and versioning.
- [**Keyboard Shortcuts**](keyboard-shortcuts.md) — Speed up your workflow.
