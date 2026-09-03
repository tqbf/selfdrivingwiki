# JSON Canvas Specification Reference

This package implements the JSON Canvas 1.0 format for read-only, accessible rendering inside an isolated WebKit renderer session.

## Canonical reference

- Specification: <https://jsoncanvas.org/spec/1.0/>
- Repository: <https://github.com/obsidianmd/jsoncanvas>
- Format version targeted: JSON Canvas 1.0 (`application/json`, `.canvas`)

The specification is published under the MIT license by the JSON Canvas project (Obsidian). The format and file layout are defined there; this package does not vendor the specification body or its reference renderer. See <https://github.com/obsidianmd/jsoncanvas> for the upstream license text.

## Supported fields

### Top level

- `nodes` (optional, array of node objects).
- `edges` (optional, array of edge objects).
- Bounded unknown top-level properties are ignored so forward-compatible extensions do not suppress rendering.

### Generic node

- `id` (required, string, unique).
- `type` (required, closed enum): `text`, `file`, `link`, `group`.
- `x`, `y` (required, finite numbers; bounded magnitude).
- `width`, `height` (required, positive finite numbers; bounded magnitude).
- `color` (optional, `canvasColor`): preset `"1"`–`"6"` or `#RGB` / `#RRGGBB` hex.

### Text nodes

- `text` (required, string): plain text with Markdown syntax.

### File nodes

- `file` (required, string): relative path within the system; validated to reject absolute paths, traversal, schemes, credentials, queries, percent escapes, backslashes, control characters, empty components, and whitespace padding.
- `subpath` (optional, string, starts with `#`).

### Link nodes

- `url` (required, string): a `[[page:<ULID>]]` / `[[source:<ULID>]]` internal reference or an HTTP(S) external URL.

### Group nodes

- `label` (optional, string).
- `background` (optional, string): path to a background image (a relative content reference admitted through `asset.read`; a color is NOT a background here).
- `backgroundStyle` (optional, closed enum): `cover`, `ratio`, or `repeat`.

### Edges

- `id` (required, string, unique).
- `fromNode`, `toNode` (required, strings referencing node IDs).
- `fromSide`, `toSide` (optional, closed enum): `top`, `right`, `bottom`, `left`.
- `fromEnd`, `toEnd` (optional, closed enum): `none` or `arrow`. Defaults: `fromEnd = none`, `toEnd = arrow`.
- `color` (optional, `canvasColor`).
- `label` (optional, string).

## Rendering behavior

- **Z-order:** nodes render in array order; the first node is lowest, the last node is highest.
- **Edges:** cubic Bézier curves anchored at the rectangle boundaries of the connected nodes. Explicit sides are honored; absent sides use a deterministic automatic side (the side facing the other node's center). `marker-start`/`marker-end` are emitted only when the corresponding end is `arrow`. Paths and markers are offset so they do not enter node interiors. Edge labels are placed at the Bézier midpoint on a readable background.
- **Text:** rendered as semantic HTML inside a node-bounded SVG `foreignObject` (paragraphs, explicit newlines, `*emphasis*`, `**strong**`, `` `code` ``, and `[label](url)` links), wrapped to node width, clipped to node height, with an explicit overflow cue. SVG `<title>`/`<desc>` and an offscreen semantic fallback expose the same content to VoiceOver and keyboard users.
- **Group backgrounds:** the background image is composed behind contained content with `cover` (fills the node), `ratio` (maintains aspect ratio), or `repeat` (tiles). The group frame, label, and tinted fallback fill remain visible when the image is unavailable.
- **Image file nodes:** the referenced image is requested through `asset.read` using the host-admitted reference key; it renders with aspect-ratio preservation. A missing, denied, unsupported, malformed, or oversized image shows a readable node fallback (filename label) and does not fail the canvas.
- **Fit/pan/zoom:** the scene is fitted to the window on load (clamped scale), with pointer-anchored wheel zoom, pointer pan, and keyboard pan/zoom/reset.

## Supported Markdown subset

Paragraphs, explicit newlines, emphasis, strong emphasis, inline code, and Markdown links. Headings, lists, block quotes, fenced code, images, raw HTML, tables, footnotes, transclusion, and unknown constructs are treated as escaped plain text (readable fallback) unless later added with dedicated bounds and tests.

## Non-goals

- No editing, persistence, or rewriting of canvas data.
- No audio/video playback, arbitrary HTML, external image loading, or Markdown transclusion.
- No `innerHTML`; the DOM is built with `createElement`/`createElementNS` + `textContent`.
- No network fetch, worker, storage, clipboard, or content-edit APIs.
- SVG (`image/svg+xml`) is not in the approved MIME declaration until the hostile-SVG image-surface isolation gate proves untrusted SVG cannot escape the image surface.
- A canvas above the bounded size limits keeps the readable Source/raw-fence fallback.

Unsupported, malformed, or unsafe values fail closed and preserve the host Source/raw-fence fallback.
