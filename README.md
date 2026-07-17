# Self-Driving Wiki — User Guide

**Self-Driving Wiki** is a native macOS app that combines a personal wiki with
an AI agent. You collect source material — PDFs, web pages, podcast episodes,
markdown notes — and the agent reads, digests, and organizes them into a
connected knowledge base of wiki pages. You ask questions, the agent answers
from (and updates) the wiki, and everything stays linked and searchable.

![Main Window](docs/user-guide/images/interface-main-window.png)

---

## Design philosophy

- **The agent maintains the wiki; you curate.** Pages are reader-first by default. The agent writes and updates content; you edit when you want to correct or guide. You don't have to hand-author every page.
- **Everything is linked.** Wiki links connect pages to pages, pages to sources, and even to specific passages inside documents. The knowledge base is a graph, not a pile of files.
- **Read-only filesystem, read/write database.** The wiki appears as a read-only folder, but all edits happen in the app or through the agent. This keeps the data consistent.  The filesystem renders links in [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) format and works seamlessly with Obsidian.
- **Native macOS feel.** Tabs like Safari, an omnibox like Safari, a sidebar like Xcode, bookmarks like a browser. If you know macOS, you know the basics.
  
---

## Core concepts

| Concept | What it means to you |
|---|---|
| **[Wiki](docs/user-guide/organizing-and-managing.md#multiple-wikis)** | A self-contained knowledge base. You can have many — a personal one, a research project, a per-book study guide. Each lives in its own window and has its own pages, sources, and chat history. |
| **[Page](docs/user-guide/pages-and-links.md)** | A wiki page written in Markdown. Pages are the curated output — summaries, entity profiles, concept explanations, indexes. The agent writes most of them; you can edit any of them. |
| **[Source](docs/user-guide/sources-and-ingestion.md)** | Raw material you bring into the wiki: a dropped PDF, a fetched web page, a Zotero attachment, an imported markdown folder, images, or even Youtube videos and podcasts. Sources are the input the agent digests into pages. |
| **[Agent](docs/user-guide/chat.md)** | The AI that maintains the wiki. It can **Ingest** sources into pages, answer questions in **Chat**, clean up formatting with **Lint**, and more. You interact with it conversationally. |
| **[Wiki link](docs/user-guide/pages-and-links.md#wiki-links--the-connective-tissue)** | The connective tissue. `[[Page Name]]` links pages to each other; `[[source:Name]]` links pages to sources. `[[chat:Name]]` links to past chats with the agent. Links are how the knowledge base stays connected and navigable. |
| **[Bookmark](docs/user-guide/organizing-and-managing.md#bookmarks)** | A user-defined shortcut to a page, source, or chat, organized into folders. Your personal table of contents. |

### The fundamental workflow

<center>
<img src="user-guide/images/cycle.jpg" alt="Workflow" style="max-width: 50%; height: auto" />
</center>

1. **[Collect](docs/user-guide/sources-and-ingestion.md#adding-sources)** — Drag in PDFs, paste URLs, import from Zotero, or drop a folder of notes.
2. **[Ingest](docs/user-guide/sources-and-ingestion.md#ingestion)** — Tell the agent to process sources. It reads them, extracts key information, and writes pages with cross-references.
3. **[Explore](docs/user-guide/pages-and-links.md)** — Browse pages, follow wiki links, search semantically, bookmark what matters.
4. **[Ask](docs/user-guide/chat.md)** — Chat with the agent about the wiki's contents. Ask it to update pages, add cross-references, or explain a concept.
5. **[Maintain](docs/user-guide/organizing-and-managing.md#the-change-log)** — Run Lint to clean up formatting. Re-ingest when sources are updated. The agent keeps `index.md` and `log.md` current.

