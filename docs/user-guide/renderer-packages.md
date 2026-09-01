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

A rich fence is named by the first word of its info string. That name is live registry data. The built-in renderers claim `mermaid` and `jsoncanvas`. The optional Excalidraw renderer package claims `excalidraw` when you install it. An installed package can claim its own names through its manifest's `fenceClaims`. A fence uses the available renderer that claims its name. Installing or removing a package changes that result on the next render without a restart.

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

Mermaid source embeds stay inline. Authored Mermaid fences use disclosure rows. Inline Mermaid SVG does not use native or installed renderer budgets.

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

Declare only roles that the package can present safely. `inlineContent` must work without disclosure chrome and must preserve readable fallback content.

Revision 1 package bytes and hashes remain unchanged. The app grants only the approved legacy `disclosureRow` role to compatible revision 1 registrations. Revision 1 packages never receive `inlineContent` authority.

The manifest role is one admission requirement. MIME matching, capabilities, byte limits, digests, exact versions, package state, and runtime resources must also pass.

Repository agents and developers must use the [`renderer-package-maintainer`](../skills/renderer-package-maintainer/SKILL.md) workflow. They must validate a package before a user imports it.

## Extractor packages are a separate system

Renderer packages add read-only views for page content. [Extractor packages](extractor-packages.md) convert PDF and HTML sources to Markdown at ingestion.

The two systems do not share an execution or security model. They use different manifest formats, different validation rules, and different catalogs. A renderer manifest is not an extractor manifest, and no package can act as both.
