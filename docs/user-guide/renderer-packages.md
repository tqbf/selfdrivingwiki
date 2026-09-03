# Renderer packages

A renderer package adds a local read-only view for a supported source format. A package is one folder on your Mac.

The folder contains `manifest.json` and the static files that the manifest declares. Static files can include HTML, JavaScript, CSS, images, and fonts.

```text
ExampleRenderer/
├── manifest.json
└── index.html
```

`manifest.json` identifies the package. It also declares matching rules, capabilities, limits, assets, and SHA-256 digests.

## Import a package

1. Open **Settings**.
2. Select **Renderers**.
3. Open **Advanced Local Renderer Package Import**.
4. Select **Import Local Renderer Package**.
5. Select the package folder.

The app validates the folder before installation. It rejects missing files, undeclared files, invalid paths, unsupported files, and incorrect digests.

The app copies a valid package for use on this Mac. The app does not use the selected source folder after import.

Every compatible installed renderer is available to every wiki on this Mac. You do not enable a package for each wiki.

Import accepts one local folder. It does not accept ZIP files, other archives, remote catalogs, signing services, or network installation.

## Renderer roles in Markdown

Markdown syntax selects the renderer role. A package can fill a compatible role, but it cannot change the role.

A rich fence is named by the first word of its info string. That name is live registry data. An optional JSON Canvas renderer package claims `jsoncanvas` when you install it. The optional Mermaid and Excalidraw renderer packages claim `mermaid` and `excalidraw` when you install them. An installed package can claim its own names through its manifest's `fenceClaims`. A fence uses the available renderer that claims its name. Installing or removing a package changes that result on the next render without a restart.

Approved rich fences use a disclosure row. The row starts collapsed and shows **Open in Window** at the trailing edge. When a renderer that has been drawing a fence becomes unavailable (its package was removed or suppressed), the fence falls back to typed raw code with a notice that the renderer is not available here; a fence nobody ever claimed stays plain code.

A claim names one alias and one inline MIME type. The declaring renderer must already fill the disclosure-row role. One alias belongs to one renderer per Mac: an import that claims an alias a built-in or another installed package already owns is rejected, and removing that package frees the alias.

Use a quoted title after an approved rich-fence name:

````markdown
```mermaid "System architecture"
graph TD
  A --> B
```
````

The quoted title does not change the renderer input or the block identity. An untitled fence uses the registered renderer name.

Use Markdown image syntax for a renderer-claimed sibling source:

```markdown
![System architecture](images/architecture.canvas)
```

Image syntax always stays inline and remains part of the reader document. A compatible renderer cannot replace it with a native attachment or promote it to a disclosure row.

The reader keeps a DOM fallback for renderer-backed images. An installed renderer package can also show **Open in Window** when exact admission succeeds.

The alt text remains available to accessibility tools and fallback content. Interactive image input has a 48,384-byte limit.

An unclaimed, unresolved, external, data, oversized, or failed image keeps its ordinary inline fallback.

A reader can keep four native or installed disclosure rows expanded. A fifth row stays collapsed until another row closes.

Mermaid is a renderer package, not a built-in renderer. Before you import it, a ` ```mermaid ` fence falls back to typed raw code with the unavailable-renderer notice. After you import it, the fence uses the generic disclosure row. The same rule applies to a `.mmd` source and to a `![[source:…mmd]]` embed: with no package, the reader shows readable code or transclusion; with the package, the reader mounts an inline package session that uses the inline budget.

## JSON Canvas

JSON Canvas is a renderer package, not a built-in renderer. It renders `.canvas` JSON documents as a read-only, accessible canvas. Before you import `RendererPackages/JSONCanvas`, a `.canvas` source or ` ```jsoncanvas ` fence stays readable source/raw code. After you import the folder through **Settings → Renderers → Advanced Local Renderer Package Import**, matching sources and the `jsoncanvas` fence use the generic renderer surface. Removed or suppressed packages restore the readable fallback.

Canvases at or below 48,000 bytes render. Larger canvases keep the readable Source/raw-code fallback. This is an accepted limit: the package bridge shares the same byte ceiling as every other renderer package.

JSON Canvas 1.1.6 renders the full JSON Canvas 1.0 visual model: text, file, link, and group nodes; preset and hex colors; edges with automatic or explicit sides and `none`/`arrow` endpoints (JSON Canvas defaults: `fromEnd = none`, `toEnd = arrow`); edge labels; multiline Markdown text (paragraphs, newlines, emphasis, strong, inline code, links) wrapped and clipped; image file nodes; and group background images with `cover`, `ratio`, or `repeat`. The scene fits the window on load; pointer and keyboard pan/zoom are supported, with light/dark appearance and Reduce Motion. Colored edges and arrowheads use their declared colors, including source-end arrows that point away from the source node and diagonal edges that attach to the nearest facing boundaries.

Image file nodes and group background images read only from exact host-pinned wiki source versions through the isolated `asset.read` bridge — the package cannot browse your wiki, read arbitrary files, or load images from the network. Supported image types are PNG, JPEG, GIF, and WebP. A missing, denied, unsupported, or unreadable image keeps a readable node fallback (the filename label or the group's tinted fill); it never breaks the whole canvas. SVG images are currently treated as unsupported (readable fallback) pending a stricter isolation gate.

JSON Canvas links are typed. Canonical `[[page:<ULID>]]` and `[[source:<ULID>]]` nodes navigate to the matching page or source after a real user activation. A relative file node (with an optional `#subpath`) resolves to the matching page or source by name — never to an arbitrary filesystem path. HTTP(S) link nodes open in your browser through the same trusted external-link flow as other packages.

## Preferences and fallback

A source can use a logical renderer preference or an exact package version. A preference does not install a package or change another source.

If a package is absent or incompatible, the app keeps Source and native renderer fallback available. The same fallback applies after a renderer failure.

Safe mode can suppress one package version after repeated failures. Resetting safe mode restores that version. It does not change source preferences.

Removing a package deletes its copied payload from this Mac. It does not delete source data or source preferences.

## Author a package

Most users only import packages. Package authors must define the full manifest, asset digests, security limits, accessibility values, and embedding roles.

Manifest revision 2 requires a nonempty `supportedEmbeddingRoles` array. Supported values are `inlineContent` and `disclosureRow`.

A revision 2 manifest may also declare fence claims. A claim is one alias plus the inline MIME type the fence bytes are handed to the renderer as:

```json
{
  "revision": 2,
  "supportedEmbeddingRoles": ["inlineContent", "disclosureRow"],
  "fenceClaims": [{ "alias": "d2", "inlineMIMEType": "text/plain" }]
}
```

Claims require the `disclosureRow` role, must be unique inside the package, and cannot use an alias a built-in or another installed package already claims. Revision 1 packages never receive fence authority. Adding or changing claims changes the package bytes, so the reviewed version must bump with them.

Manifest revision 3 adds an optional fence-syntax validation declaration to a claim. The declaration names two package assets and one JavaScript function. The host runs a format-neutral validator: it evaluates the wrapper asset first, then the engine asset, then calls the entry function with each claimed fence's text. The wrapper must define the entry function on the global object and return a holder object with `done`, `isValid`, `diagramType`, and `errors`. The engine that renders is the engine that validates, so no version skew can occur.

```json
{
  "revision": 3,
  "supportedEmbeddingRoles": ["inlineContent", "disclosureRow"],
  "fenceClaims": [
    {
      "alias": "mermaid",
      "inlineMIMEType": "text/mermaid",
      "validation": {
        "engineAssetPath": "mermaid.min.js",
        "wrapperAssetPath": "validate.js",
        "entryFunction": "__sdw_validate_fence"
      }
    }
  ]
}
```

The declaration rules are:

- The engine and wrapper paths must be two distinct assets. Each must be approved by the declaring descriptor and declared in the top-level asset list.
- The entry function must be one JavaScript identifier.
- A revision 1 or 2 manifest that carries a `validation` object is rejected.
- The wrapper asset runs first so it can install anything the engine needs before the engine loads.

Save-time validation runs only where the declaring package is installed. In the app, the editor shows a non-blocking warning banner. In `wikictl page save`, an invalid claimed fence aborts the save before the write. When a claimed-looking fence has no installed declaring package, the save continues and `wikictl` prints a one-line notice that validation was skipped.

Declare only roles that the package can present safely. `inlineContent` must work without disclosure chrome and must preserve readable fallback content.

Revision 1 package bytes and hashes remain unchanged. The app grants only the approved legacy `disclosureRow` role to compatible revision 1 registrations. Revision 1 packages never receive `inlineContent` authority.

The manifest role is one admission requirement. MIME matching, capabilities, byte limits, digests, exact versions, package state, and runtime resources must also pass.

Repository agents and developers must use the [`renderer-package-maintainer`](../skills/renderer-package-maintainer/SKILL.md) workflow. They must validate a package before a user imports it.

## Extractor packages are a separate system

Renderer packages add read-only views for page content. [Extractor packages](extractor-packages.md) convert PDF and HTML sources to Markdown at ingestion.

The two systems do not share an execution or security model. They use different manifest formats, different validation rules, and different catalogs. A renderer manifest is not an extractor manifest, and no package can act as both.
