# Pages & Links

Pages are the heart of your wiki. They're written in Markdown, maintained by the
agent, and connected to each other through wiki links. This page covers
everything you can do with pages as a user.

---

## Reading pages

Pages open in **reader mode** by default — a clean, formatted rendering of the
Markdown. You see:

- **Headings** with hierarchy (H1–H6), clickable in the outline.
- **Formatted text** — bold, italic, inline code, blockquotes.
- **Tables, lists, and code blocks** with syntax highlighting.
- **Wiki links** — clickable, styled links that navigate within the app.
- **External links** — open in your default browser (shown with a ↗ glyph).
- **Images and embeds** — inline media (images, PDFs, videos, audio).
- **Mermaid diagrams** — flowcharts and sequence diagrams rendered as SVG.
- **Footnotes** — superscript numbers that link to footnote definitions at the bottom.

### The outline

Click the **outline toggle** (sidebar.right icon in the page header) to open a
trailing panel listing all headings. Click a heading to scroll to that section.
The outline works in both reader and edit mode.

### Zoom

| Shortcut | Action |
|---|---|
| ⌘+ or ⌘= | Zoom in (×1.1 each step) |
| ⌘− | Zoom out (÷1.1 each step) |
| ⌘0 | Reset to 100% |

Reader zoom and editor zoom are **independent** — changing one doesn't affect
the other. Both persist across sessions. Range: 50%–300%.

You can also access zoom from the **Page menu** (click the leading icon in the
address bar).

### Find on page

| Shortcut | Action |
|---|---|
| ⌘F | Toggle the find bar |

The find bar overlays the top of the content area:
- Type to search — match count shows "X of Y."
- **‹ ›** buttons (or Enter / Shift+Enter) navigate matches.
- **Aa** toggle switches case sensitivity.
- **Done** or Escape dismisses the find bar.

You can also open Find from the **Page menu** in the address bar.

---

## Editing pages

Click the **Edit** button (pencil icon) in the page header to enter edit mode.
The rendered view swaps for a monospaced text editor showing raw Markdown.

| Action | How |
|---|---|
| Save | ⌘S or "Save Changes" button |
| Cancel | Escape or "Cancel" button |
| Toggle outline | Outline icon remains available |

**Edit state is per-tab** — if you switch tabs and come back, your edit session
is preserved. Closing a tab while editing asks for confirmation.

**Navigation exits edit mode** — clicking a wiki link or sidebar item saves and
exits. The agent's Lint runs automatically on save, cleaning up formatting
(whitespace, blank-line spacing, trailing newline) and fixing common wiki-link
errors.

---

## Wiki links — the connective tissue

Wiki links are the most powerful feature for connecting knowledge. They use
double-bracket syntax:

### Link types

| Syntax | What it does |
|---|---|
| `[[Page Name]]` | Links to a page by name. Navigates when clicked. |
| `[[Page Name\|Display Text]]` | Links to a page but shows custom text. |
| `[[Page Name#Section]]` | Links to a page and scrolls to the heading "Section." |
| `[[source:Source Name]]` | Links to a source (PDF, web page, etc.). |
| `[[source:Name#"quoted passage"]]` | Links to a source and highlights the exact quoted text. |
| `[[source:Name#Section]]` | Links to a source and scrolls to a heading. |
| `[[source:Name@v3#"quote"]]` | Links to a specific extraction version (v3) of a source. |
| `[[#Section]]` | Scrolls within the current page to a heading. |
| `[[chat:Chat Title]]` | Links to a chat conversation. |
| `[[chat:Title#"quote"]]` | Links to a chat and highlights the quoted text. |
| `![[source:Name]]` | Embeds a source inline (image, video, audio, PDF). |

### How links behave

- **Resolved links** are styled normally (blue, underlined on hover). Clicking
  navigates to the target. Hovering shows a tooltip with the target's title.
- **Ghost links** (the target doesn't exist yet) render in **red**. This helps
  you spot missing pages the agent should create — or that you mistyped a name.
- **Page links** navigate to a heading by slug. Clicking `[[Methods#Results]]`
  opens the Methods page and scrolls to the Results heading.
- **Source quote links** scroll to and **highlight** the exact passage. The
  highlight uses the system find-highlight color. This works on both markdown
  sources and PDFs.
- **Version-pinned links** (`@vN`) lock a quote to a specific extraction. If you
  re-extract a PDF and the text shifts, a pinned link still highlights the
  passage from the version it was created against.

### Link context menus

Right-click any link in a page for a context menu:

| Menu item | When it appears | What it does |
|---|---|---|
| **Suggest…** | On a ghost (red) link | Shows closest-matching pages from semantic search. Pick one to fix the link. |
| **Find Similar…** | On any wiki link | Shows pages semantically similar to the linked target. |
| **Copy as Wiki Link** | On any wiki link | Copies `[[Target]]` to clipboard (preserves alias and fragment). |
| **Add as Source** | On an `https://` link | Opens the "Add from URL" sheet pre-filled with the URL. |
| **Add Bookmark…** | On a resolved wiki link | Files the target into a bookmarks folder. |
| **Open in Browser** | On an external link | Opens the URL in your default browser. |
| **Copy Link** | On an external link | Copies the URL to clipboard. |

---

## Creating pages

Most pages are created by the agent during **ingest**. But you can create pages
manually:

1. Click **+ New Page** in the Pages sidebar header (or the welcome screen).
2. A new tab opens with a timestamped title (e.g., "Untitled 2026-07-16 14:30:45").
3. Click **Edit** to start writing.
4. The title is editable — click it in the header to rename.

**Title collisions are prevented.** If you try to rename a page to a title that
already exists, the rename is blocked with an alert. This matters because wiki
links resolve by title — a collision would make links ambiguous.

---

## Embeds

Use `![[source:Name]]` to embed media directly in a page:

| Source type | How it renders |
|---|---|
| **Image** (PNG, JPEG, etc.) | Inline image. |
| **PDF** | Inline iframe viewer. |
| **YouTube / Vimeo** | Embedded video player. |
| **Spotify / SoundCloud** | Embedded audio player. |
| **Apple Podcasts** | Embedded podcast player. |
| **Direct audio/video** (mp3, mp4, HLS) | Native `<audio>` / `<video>` element. |

Embeds let you reference source material visually within a page's narrative.

### Embedding a YouTube video (or other web media)

You don't have to download media to embed it. Paste a YouTube, Vimeo, Spotify,
SoundCloud, or Apple Podcasts URL via **[Add from URL](sources-and-ingestion.md#from-a-url)**
and the app creates a lightweight **byteless** source — nothing is downloaded;
it just remembers the provider and video/episode id. Then reference it like any
other source:

```
![[source:My Conference Talk]]
```

That renders an inline player (a YouTube iframe, a Spotify widget, an Apple
Podcasts player, etc.) right in the page. The source stays citable and
searchable in the Sources list, and the agent can embed it into pages the same
way you would.

---

## Special pages

Every wiki has some special pages maintained by the agent:

| Page | What it is |
|---|---|
| **Home** | The landing page, seeded on wiki creation. You can configure any page as the home page. |
| **index.md** | A curated catalog of the wiki's pages, organized by topic. The agent maintains this. |
| **log.md** | A chronological, append-only log of agent operations. Visible in the Change Log sidebar. |
| **CLAUDE.md / AGENTS.md** | The system prompt — instructions the agent reads each run. Editable by you. |

You can open any of these from the sidebar or the menu bar. The system prompt
has its own tab type and a dedicated header explaining its role.

---

## Tips for working with pages

- **Let the agent do the heavy lifting.** Instead of writing pages from scratch,
  ingest sources and let the agent draft them. Then refine.
- **Use wiki links liberally.** The more connected your wiki, the more useful the
  agent's answers become — it follows links to gather context.
- **Cite sources with quotes.** `[[source:Paper#"the results show…"]]` creates a
  clickable citation that highlights the exact passage. Use this in footnotes:
  `[^1]: Supported by [[source:Paper#"…"]]`.
- **Watch for ghost links.** Red links mean a page doesn't exist yet. Right-click
  → **Suggest…** to find a close match, or ask the agent to create the missing page.
- **Bookmark your go-to pages.** Pages you visit often should live in bookmarks
  for one-click access.
