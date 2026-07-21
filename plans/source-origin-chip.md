# Plan: Source origin chip — click to reveal + combined label

## Goal
1. When a source's origin chip says "Folder" (markdown-folder) or "File" (local-file), clicking it should reveal the original folder/file in Finder.
2. The chip label should include the content type, e.g. "Folder / Markdown", "File / PDF" — using the existing `SourceProvenanceLabel.combine` helper.

## Current state

### The chip renderer (`providerOriginTag`, SourceDetailView.swift:812)
- `markdown-folder` → `Label("Folder", systemImage: "folder")` — NOT clickable
- `local-file` → `Label(fileLabel, systemImage: "doc")` where `fileLabel` uses `SourceProvenanceLabel.combine(provider: "File", ...)` = "File / PDF" etc. — NOT clickable
- `website`/`apple-podcast`/media → already clickable (Button + `NSWorkspace.shared.open(url)`)

### The path data gap
- `MarkdownFolderMaterializer` (SourceMaterializer.swift:481) takes `filename` + `data` but NOT the folder directory URL. It doesn't set `plan` or `externalRef` — the folder path is lost at import time.
- `LocalFileMaterializer` (SourceMaterializer.swift:186) takes `fileURL` but doesn't set `plan` or `externalRef` — the file path is lost.
- `importFromMarkdownFolder(directory:)` (WikiStoreModel.swift:2658) receives `directory: URL` but passes only `filename`/`data` to the materializer — the directory URL is not persisted.
- `SourceOrigin.externalRef` and `.plan` are `nil` for local-file and markdown-folder sources.

## Implementation

### 1. Persist the folder/file path at import time

**`MarkdownFolderMaterializer`** — add an optional `directoryURL: URL?` parameter. Use it as `plan` in the `SourceProvenance`:
```swift
public struct MarkdownFolderMaterializer: SourceMaterializer {
    public let agentName = "markdown-folder"
    public let filename: String
    public let data: Data
    public let mimeType: String?
    public let directoryURL: URL?  // NEW

    public init(filename: String, data: Data, mimeType: String? = nil, directoryURL: URL? = nil) {
        ...
        self.directoryURL = directoryURL
    }

    public func materialize() async throws -> MaterializedSource {
        MaterializedSource(
            ...
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "import",
                // Store the folder path so the origin chip can reveal it:
                plan: directoryURL?.path,
                externalRef: directoryURL?.path
            )
        )
    }
}
```

**`LocalFileMaterializer`** — set `plan`/`externalRef` to the file URL's path:
```swift
public func materialize() async throws -> MaterializedSource {
    MaterializedSource(
        ...
        provenance: SourceProvenance(
            agentName: agentName,
            activityKind: "import",
            plan: fileURL.path,
            externalRef: fileURL.path
        )
    )
}
```

**`importFromMarkdownFolder`** — pass `directoryURL` to the materializer:
```swift
let provider = MarkdownFolderMaterializer(
    filename: file.filename, data: file.data,
    mimeType: mimeType,
    directoryURL: directory)  // NEW
```

### 2. Make `markdown-folder` chip clickable + combined label

In `providerOriginTag`, change the `markdown-folder` case:
```swift
case "markdown-folder":
    let folderLabel = SourceProvenanceLabel.combine(
        provider: "Folder", agentName: origin.agentName,
        ext: file.ext, mimeType: file.mimeType)
    let folderPath = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
    if !folderPath.isEmpty {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folderPath)])
        } label: {
            Label(folderLabel, systemImage: "folder")
        }
        .buttonStyle(.link)
        .help("Reveal original folder: \(folderPath)")
    } else {
        Label(folderLabel, systemImage: "folder")
    }
```

### 3. Make `local-file` chip clickable

In `providerOriginTag`, change the `local-file` case (currently the `default` branch):
```swift
// Currently:
let fileLabel = SourceProvenanceLabel.combine(provider: "File", ...)
Label(fileLabel, systemImage: "doc")

// Change to:
let filePath = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
if !filePath.isEmpty {
    Button {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
    } label: {
        Label(fileLabel, systemImage: "doc")
    }
    .buttonStyle(.link)
    .help("Reveal original file: \(filePath)")
} else {
    Label(fileLabel, systemImage: "doc")
}
```

### 4. Use `NSWorkspace.shared.activateFileViewerSelecting`
For folders: `activateFileViewerSelecting([folderURL])` — opens Finder with the folder selected (or reveals it if buried).
For files: same — reveals the file in its containing folder.

## Files to modify
| File | Change |
|---|---|
| `Sources/WikiFSCore/Sources/SourceMaterializer.swift` | `MarkdownFolderMaterializer`: add `directoryURL`; set `plan`/`externalRef`. `LocalFileMaterializer`: set `plan`/`externalRef` to `fileURL.path`. |
| `Sources/WikiFSCore/Store/WikiStoreModel.swift` | `importFromMarkdownFolder`: pass `directory` to `MarkdownFolderMaterializer`. |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | `providerOriginTag`: make `markdown-folder` + `local-file` chips clickable (Button + NSWorkspace reveal); use `SourceProvenanceLabel.combine` for `markdown-folder` label. |

## Acceptance criteria
- [ ] The "Folder" chip shows "Folder / Markdown" (or "Folder / PDF", etc.) using the content type.
- [ ] The "File" chip already shows "File / PDF" (or similar) — verify it still does.
- [ ] Clicking the "Folder" chip reveals the original folder in Finder.
- [ ] Clicking the "File" chip reveals the original file in Finder.
- [ ] Sources imported BEFORE this change (no path stored) show the chip but without click behavior (graceful degradation).
- [ ] `make build && make test` passes.
- [ ] No `print`; no bare `try?`.

## Gotchas
1. **Existing sources won't have the path** — the `plan`/`externalRef` columns are NULL for pre-change sources. The chip should render as a non-clickable `Label` when the path is empty (graceful degradation). The `if !folderPath.isEmpty` guard handles this.
2. **`NSWorkspace.shared.activateFileViewerSelecting`** requires a valid `URL(fileURLWithPath:)`. If the path no longer exists (folder moved/deleted), Finder will show an error — that's acceptable (no need to pre-check existence).
3. **`SourceProvenanceLabel.combine`** is already used for the File label — just apply the same to the Folder label.
4. **File overlap**: the `source-history-tab` agent also touches SourceDetailView.swift. Different region (provenance origin chip vs history tab inspector). Rebase if needed.
5. **The `SourceProvenance` init change** (adding `plan`/`externalRef`) — these parameters already exist on the struct, just not set by the local materializers. No struct change needed; just pass values to the existing init.
