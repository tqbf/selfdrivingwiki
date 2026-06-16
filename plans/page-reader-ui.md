# Page Reader UI

Self Driving Wiki is agent-maintained first and manually edited only occasionally. The main
page surface should therefore behave like a wiki reader, not a source editor.

## Product Direction

- Normal page selection opens a rendered article view.
- Manual editing is an explicit mode, entered through the page's Edit action.
- Edit mode is a focused source editor: title + markdown body, no side-by-side
  preview.
- Agent runs still lock manual editing so app autosave cannot clobber `wikictl`
  writes.
- Rendered wiki links remain clickable and use the same model selection path as
  the sidebar.

## Current Implementation

- `PageDetailView` owns the `isEditing` mode and the `Edit Page` / `Done Editing`
  toolbar action (`Command-E`).
- `PageReaderView` renders the page title plus `MarkdownPreview` in a readable
  column. If the markdown body starts with the same `# Title`, the reader hides
  that duplicate heading.
- `PageEditorView` contains the manual title field and markdown `TextEditor`,
  preserving the existing draft buffer + debounced autosave path.
- `MarkdownPreview` constrains rendered blocks to the shared readable content
  width.

## Follow-Ups

- Consider giving the reader a richer block renderer for headings/lists instead
  of relying on inline Markdown parsing.
- Consider whether the System Prompt should stay editor-first; it is one of the
  few documents users intentionally edit, so it may be the right exception.
