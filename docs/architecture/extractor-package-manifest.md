# Extractor package manifest

This document is the normative reference for the extractor package manifest, revisions 1 through 4, and for the package digest.

Sources of truth in code:

- Manifest, limits, launch, registrations: `Sources/WikiFSTypes/Extractor/ExtractorManifest.swift`
- Identities and digest primitives: `Sources/WikiFSTypes/Extractor/ExtractorIdentity.swift`
- Path and MIME validation: `Sources/WikiFSTypes/Extractor/ExtractorContractTypes.swift`
- Secure admission, mode normalization, and snapshots: `Sources/WikiFSCore/Extractor/ExtractorDirectoryAdmission.swift`
- Catalog record and index schema: `Sources/WikiFSTypes/Extractor/ExtractorPackageCatalog.swift`
- Validation CLI: `swift run extractor-package-tool validate <folder>`

## Package layout

An extractor package is one local directory. It contains `manifest.json` and the files that the manifest declares. No other layout is valid.

```text
Defuddle/
├── manifest.json
├── LICENSE
├── PROVENANCE.md
└── bin/
    └── defuddle-extractor.js
```

Import accepts one local directory only. The store rejects a single file, an archive, a URL, and any remote source.

## Manifest fields

`manifest.json` revision 1 uses these fields. Unknown fields are rejected. Each field is required unless marked optional.

| Field | Type | Rules |
| --- | --- | --- |
| `manifestRevision` | integer | Must be `1`. |
| `packageID` | string | Stable lineage. Lowercase reverse-DNS labels, at least two labels, each label at most 63 characters. |
| `version` | string | Strict semantic version: `major.minor.patch` with optional prerelease and build metadata. |
| `displayName` | string | 1 to 128 bytes after trimming. |
| `protocolRevision` | integer | Must be `1`. |
| `entryPoint` | string | Package-relative path. Must be declared in `files`. |
| `launch` | object | `{"mode":"direct"}` or `{"mode":"runtime","command":"...","arguments":[...]}`. |
| `registrations` | array | One or more registration objects. |
| `capabilities` | array | Subset of the closed set below. |
| `files` | array | One or more `{path, digest}` objects. |
| `limits` | object | Operation limits within host policy. |

### Launch modes

- `direct`: the host executes the entry point itself. The source entry point must be a regular file with owner-read and owner-execute permission.
- `runtime`: the host executes one command and passes the entry point path as the last argument. The command is a single name with no slash, at most 128 characters, from `[A-Za-z0-9._+-]`. The source entry point must be a regular file with owner-read permission. Execute permission is not required. Fixed arguments are optional, at most 64 arguments of at most 8 KiB each.

The user's login shell selects the executable. The host asks the account's configured login shell (zsh, bash, or fish, started as an interactive login shell) which absolute executable it runs for the command name, accepts exactly one absolute path, and pins that file's identity. The host retains that one resolution for the whole prepared operation: readiness and every launch use the same result, and nothing searches a PATH again. The host launches the retained absolute path directly, so the managed child receives no `PATH` and no tool-manager configuration. Bun and uv are the runtimes the reviewed packages use. They are optional user-installed tools, not app dependencies; any installation method works when the login shell resolves the name. A resolution failure is typed (account shell, shell family, shell start, startup timeout, shell exit, command absent, unexpected shell output, unusable executable), readiness reports it as setup guidance, and the next prepared operation resolves again.

### Registrations

**Kind neutrality.** Extractor-kind policy comes from package data, not host
branches. The manifest registrations declare what a package can extract, which
MIME types and filename extensions it recognizes, and import-time
auto-extraction follows that data: a kind converts on import when an active
registration claims it and the host route catalog has no built-in route for it
(package-only). Host code never compares against an extractor kind to decide
recognition, selection, or import behavior, and never names a policy seam
after a kind. Typed per-kind extractor protocols keep their kind names
because their operation shapes differ; kind-to-value mapping tables (MIME
fallbacks, labels) are data, not policy. `ExtractorKindNeutralityContractTests`
enforces the boundary.

| Field | Type | Rules |
| --- | --- | --- |
| `id` | string | 1 to 64 characters, lowercase ASCII letters, digits, hyphens. |
| `displayName` | string | 1 to 128 bytes. |
| `role` | string, optional (revision 4) | `extractor` (default) or `fetcher`. Revisions 1–3 reject the key; every older registration is an extractor. Revision-4 canonical encoding always writes it. |
| `kinds` | array | Required for extractors, FORBIDDEN for fetchers. Extractors: nonempty subset of `pdf`, `html`, `docx`, `podcast-transcript`, `apple-podcast-transcript`, and `youtube-transcript`. The retired `zotero` kind is rejected; catalog records carrying it are skipped at read time. |
| `mimeTypes` | array | Nonempty set of normalized lowercase MIME types. For extractors this is the input format. For fetchers this is the claimed input MIME set — the synthetic source MIME types of the byteless sources the fetcher can acquire. A `podcast-transcript` registration must declare its route MIME, typically the synthetic `audio/podcast` source MIME. An `apple-podcast-transcript` registration declares the synthetic `audio/apple-podcast` source MIME. A `youtube-transcript` registration declares the synthetic `video/youtube` source MIME. |
| `filenameExtensions` | array, optional | Lowercase ASCII letters and digits, no leading dot, at most 32 characters. Must be empty for fetchers. |
| `wantsAgentCleanup` | boolean, optional (revision 5) | The registration declares that the Markdown it produces is raw enough that the host should run a best-effort agent cleanup pass after the extraction lands (issue #1379). Defaults to `false`; encoded only when `true`, so revision 1–4 canonical bytes and package digests are unchanged. Revisions 1–4 reject the key (unknown-field policy). |

Duplicate values inside one registration are rejected. Duplicate registration IDs in one manifest are rejected.

### Roles (manifest revision 4)

Revision 4 adds the explicit registration role. The role is package data — never inferred from URL transport, MIME type, provider, or package ID — and decides which claim surface the registration owns:

- `extractor` converts content it is handed (staged bytes or a remote URL) into Markdown. Declares one or more operation `kinds`.
- `fetcher` acquires ONE remote source per request (protocol revision 5, `remote-url`) and reports either exact `source-bytes` or the finished `markdown`. Declares NO kinds and NO filename extensions; its `mimeTypes` are the claimed input MIME set — the synthetic source MIME types of the byteless sources it can acquire.

Fetcher rules, enforced at manifest validation:

- Manifest revision must be 4 and protocol revision must be 5.
- The manifest capabilities must include `network`.
- A sync declaration's `sourceMIMEType` must be one of the fetcher's claimed input MIME types, so the byteless sources the sync creates are exactly ones the fetcher claims.
- A fetcher's claims live in their own route and registry namespaces (`FetcherRouteID`, `.installedFetcher`), so a same-MIME extractor can never replace a fetcher selection or the reverse.

Revisions 1–3 reject the `role` key outright (unknown-field policy); every older registration decodes as an extractor. Revision-1/2/3 canonical bytes and package digests are unchanged. Revision-4 canonical encoding always writes `role`, including for plain extractors.

### Agent-cleanup claims (manifest revision 5)

Revision 5 adds one optional registration field: `wantsAgentCleanup`. It is package data, not host policy — the host consults the ACTIVE registrations' claims (the same `RegisteredExtractionInputs` surface that drives import recognition), never a kind comparison. When a registration with the claim produces a transcript that lands as a source's raw head, the host runs a best-effort agent cleanup pass over it and appends the cleaned copy as a new version parented to the raw head; the raw transcript always stays in history. A failed or unavailable cleanup pass is logged and the raw head remains canonical — the claim never turns an extraction into a failure. The reviewed `YouTubeTranscript` package declares the claim (raw auto-captions are hard to read); the podcast transcript packages do not (publisher transcripts are usually already clean).

Revisions 1–4 reject the `wantsAgentCleanup` key outright (unknown-field policy). Revision-1–4 canonical bytes and package digests are unchanged; revision-5 encoding writes the key only when the claim is set.

### Sync declarations (manifest revision 3)

Revision 3 adds one optional registration field: `sync`, the acquisition-sync declaration. A registration that carries `sync` is syncable: `wikictl extractor sync <short-name>` loads the declared config sidecar, interpolates the URL template, and enqueues one byteless source per configured item. The host side of that flow is generic — every package-specific fact is here, in package data. The short name is the package ID's last label (`org.selfdrivingwiki.zotero` → `zotero`).

| Field | Shape | Rules |
| --- | --- | --- |
| `configFileName` | string | The sidecar file name in the App Group container. At most 128 bytes, no path separators, not `.` or `..`. |
| `urlTemplate` | string | The byteless source URL template with `{placeholder}` tokens. At most 512 bytes. Tokens must be declared field names plus `{itemKey}`, which must appear exactly once. Sample interpolation must form a valid absolute HTTPS URL. |
| `fields` | array | One entry per config field: `name` (1–64 ASCII alphanumerics, starts with a letter), `required`, optional bounded `pattern`, optional `isList`. At most 8 fields, unique names, EXACTLY ONE list field. |
| `itemValidation` | object, optional | Validation for the list field's items: `minimumLength` and `maximumLength` (UTF-8 bytes, 1–256), plus exactly one of `alphabet` (a string of unique characters) or `pattern` (a bounded regex). Neither means length-only validation. Patterns are whole-value matches. |
| `sourceMIMEType` | string, optional | The MIME type of the created byteless sources. When absent, the registration must declare exactly one MIME type. |

A sync declaration supports at most one REQUIRED credential requirement on its registration: the sync's credential gate has one subject. Zero required requirements is allowed — a package with no required credentials syncs without the gate. Patterns must compile; they are validated at decode time so a broken declaration fails admission, never a later sync run.

Revision 1 and 2 reject the `sync` key outright (unknown-field policy), so only a revision-3 manifest can declare syncability. Revision-1/2 canonical bytes and package digests are unchanged.

#### Catalog read tolerance

A catalog record whose persisted `manifestRevision` is newer than the reading host understands is skipped with a diagnostic, not treated as corruption: the whole catalog still reads, and the record's reservations survive. A mixed-version machine (app published a newer record, CLI not yet updated) degrades to "that package is invisible to this host" instead of an unreadable catalog.

A record whose registrations declare the RETIRED `zotero` extractor kind is also skipped whole, with its own bounded read-time count. The fetcher role replaced that kind; the retired record's digest reservation survives untouched and the durable catalog bytes are never rewritten by a read. Every other record decodes strictly — unrelated malformed data remains fatal.

### Capabilities

The set is closed: `network`, `shared-runtime-cache`, `model-download`.

- `model-download` requires `network`. The combination `model-download` without `network` is rejected.
- A capability is a reviewed declaration about behavior. It grants the matching shared-cache environment variable and nothing else. Capability declarations are not an operating-system sandbox, and Cordis lifecycle does not create one.

### Limits

`ExtractorHostLimits` fixes host policy. A manifest limit must be a positive integer at or below the policy value.

| Manifest field | Host policy |
| --- | --- |
| `maximumInputByteCount` | 128 MiB |
| `maximumMarkdownOutputByteCount` | 128 MiB |
| `maximumDurationMilliseconds` | 30 minutes |
| `maximumProgressEventCount` | 10,000 |

## Package digest

The package digest identifies the exact bytes of one revision. Compute it this way:

1. Encode the manifest as canonical JSON with sorted keys and no escaped slashes. In the canonical form, `files` is the ordered list of package-relative paths.
2. Wrap the canonical manifest in this envelope, with each declared file as `{"path": ..., "sha256": ...}`:

```json
{
  "format": "selfdrivingwiki.extractor-package-digest",
  "revision": 1,
  "manifest": { },
  "files": [ ]
}
```

3. Encode the envelope as JSON with sorted keys and take the SHA-256 digest.

The digest is exactly 32 bytes, written as lowercase hexadecimal. Source file modes, timestamps, installation paths, and `installedAt` are not digest inputs. The Swift code in `ExtractorManifest.packageDigest()` defines this algorithm. The sync script does not compute it.

## Identities

- `ExtractorPackageID` is the stable package lineage, for example `org.selfdrivingwiki.pdf2md`.
- `ExtractorPackageVersion` is one semantic version.
- `ExtractorPackageDigest` is the package digest above.
- `ExtractorPackageRevisionID` is the triple of package ID, version, and digest. It identifies immutable bytes.
- `ExtractorRegistrationID` is one registration inside the package.
- `ExtractorReference` is an exact revision plus one registration.
- `LogicalExtractorReference` is a package lineage plus one registration, without a version.

These namespaces stay distinct from renderer, Cordis plugin, Cordis component, activation-run, and extraction-request identities.

## Validation and admission

The app validates a package before it stores anything. Validation rejects:

- unsupported manifest or protocol revisions.
- invalid identifiers, versions, paths, MIME types, and digests.
- duplicate registrations, duplicate paths, and duplicate values.
- normalized path collisions. Paths are compared after canonical precomposition with case-insensitive and diacritic-insensitive folding, so `Doc.md` and `doc.md` collide.
- an entry point that `files` does not declare.
- undeclared files in the directory.
- absolute paths and parent traversal (`..`).
- symlinks, hard links, devices, sockets, and FIFOs.
- source identity, metadata, or mode changes during the copy.
- more than 1,024 files or more than 64 MiB of package bytes.
- capability inconsistencies and limits above host policy.

The store copies the source directory into fresh staging without following links and validates only the staged copy. The source directory is never used again.

### Installed file modes

The installer normalizes modes at rest and rechecks them before every spawn and before every operation snapshot:

- directories: `0700` (owner-only traversal).
- ordinary files: `0400` (owner read-only).
- the entry point of a `direct` launch: `0500` (owner read and execute).

A mode change on installed bytes is an admission failure. Mode bits are host-derived invariants, not digest inputs.

## Catalog record and index

The durable machine catalog stores one record per installed revision: revision identity, display name, protocol revision, launch, registrations, capabilities, `installedAt` (RFC 3339), and at most 16 admission diagnostics. Each diagnostic is at most 512 bytes and contains no slash or backslash.

The index file is `derived/index.json` under the store root. Its schema version is 1. It carries a monotonically increasing `generation`, sorted unique records, and digest reservations. A reservation binds one package ID and version to one digest, so an import cannot silently replace installed bytes. Readers always observe one complete generation.

## Configuration compatibility

`extraction-config.json` stores two generic selection tables: `routeExtractors` (extractor routes — a typed route of kind plus MIME type, each naming a version-free reference) and `routeFetchers` (fetcher routes — a `FetcherRouteID` of the synthetic source MIME, naming the fetcher lineage that acquires such sources). The two tables have distinct key types, so a fetcher selection and an extractor selection can never collide or overwrite one another. Both are sorted arrays; encode never writes retired keys.

One-time migration. The retired `backend`, `htmlBackend`, `pdfExtractor`, and `htmlExtractor` keys are decode-only inputs. The decoder adopts each retired value into the matching route record when no record claims that route: `backend` values become host references (`localPdf2md` leaves the record absent, because the bundled default supplies it), and `htmlBackend` values become host references. Encode never writes the retired keys again. The retired Zotero EXTRACTOR route record (`kind: "zotero"`) no longer decodes — the kind is retired — so a saved record of that shape is dropped non-fatally at decode; the fetcher default supplies the route instead.

Defaults. Fresh installs and record-less routes resolve through the bundled default-route policy (`default-routes.json`): the PDF route defaults to the reviewed pdf2md lineage, and the DOCX route to the reviewed docx2md lineage (`org.selfdrivingwiki.docx2md`, registration `document`). HTML has no shipped default — the user picks an extractor, and the built-in tag-based adapter is the execution floor. The fetcher table's bundled default routes `application/zotero` to the reviewed Zotero fetcher lineage (`org.selfdrivingwiki.zotero`, registration `attachment`). An explicit no-default record disables the shipped default for its route.

Failure posture. An installed selection with no compatible active registration keeps its saved identity, emits one redacted diagnostic, and fails closed. The app never silently selects a different third-party package.

Legacy host identities keep working. A migrated `localPdf2md`, `doclingServe`, or `defuddle` host reference maps to its reviewed package lineage (`org.selfdrivingwiki.pdf2md` / `org.selfdrivingwiki.docling-serve`, registration `document`; `org.selfdrivingwiki.defuddle`, registration `article`) when that lineage is active, and fails closed when it is not.

## Worked examples

The reviewed packages in `ExtractorPackages/` are complete reviewed packages:

- `Defuddle/manifest.json` — HTML article extraction, `runtime` launch with the `bun` command, no capabilities, 120-second duration limit, 32 MiB input and output limits.
- `Pdf2md/manifest.json` — PDF conversion, `runtime` launch with the `uv` command and `run --script` arguments, `network`, `shared-runtime-cache`, and `model-download` capabilities, 30-minute duration limit, 128 MiB input limit.
- `DoclingServe/manifest.json` — PDF conversion through a self-hosted Docling Serve, `direct` launch, manifest revision 2 with an optional `api-token` credential requirement, `network` capability.
- `PodcastTranscript/manifest.json` — RSS podcast transcript conversion, `uv run --script` launch, manifest revision 1 with protocol revision 3 (the `remote-url` transport and the `podcast-transcript` kind are registration data, not manifest fields), `network` and `shared-runtime-cache` capabilities.
- `ApplePodcastTranscript/manifest.json` — Apple Podcasts episode TTML transcript conversion, same launch and manifest shapes, registering only `apple-podcast-transcript` for `audio/apple-podcast`, `network` capability only. The signed `podcast-token-helper` is deliberately NOT a package file: code signing rewrites Mach-O bytes, which would break the digest contract. The host stages the helper into the private operation root for this exact revision; the request's operation configuration carries only the staged helper's relative path.
- `YouTubeTranscript/manifest.json` — YouTube caption conversion, `uv run --script` launch, manifest revision 5 with protocol revision 3, registering only `youtube-transcript` for `video/youtube` with the `wantsAgentCleanup` claim (issue #1379 — the raw auto-captions want the host's best-effort agent cleanup pass), `network` and `shared-runtime-cache` capabilities (the shared cache keeps uv's CPython install and wheel cache warm across operations). The package fetches only the captions YouTube exposes: `youtube-transcript-api` is the primary route, and an eligible primary failure (no track, disabled captions, ordinary retrieval error) makes ONE yt-dlp attempt to fetch the same captions' WebVTT subtitle bytes — never media, never speech-to-text. The pinned yt-dlp release requires a JS runtime at or above Bun 1.2.11 for its solver; the host resolves Bun through the login-shell locator and grants it to the exact reviewed revision through the operation-configuration envelope, so the package never searches a `PATH`. A blocked request (IP block / 429) never reaches the fallback, and a listed caption track is not proof of access — the transcript publishes only when actual subtitle bytes arrive.
- `Zotero/manifest.json` — Zotero attachment acquisition as a FETCHER, `uv run --script` launch, manifest revision 4 with protocol revision 5. A worked example (see below): one `attachment` registration with `role: "fetcher"` claiming the synthetic `application/zotero` MIME, a REQUIRED `zotero-api-key` secret requirement, the acquisition-sync declaration, and the `network` + `shared-runtime-cache` capabilities. The package downloads ONE attachment file plus its item metadata through the Zotero Web API and never converts formats.

### Worked example: the Zotero fetcher package

The Zotero package is the reference for a credential-declaring, sync-declaring FETCHER package (manifest revision 4, protocol revision 5):

```json
{
  "manifestRevision": 4,
  "packageID": "org.selfdrivingwiki.zotero",
  "version": "1.1.0",
  "displayName": "Zotero Attachment",
  "protocolRevision": 5,
  "entryPoint": "bin/zotero-extractor",
  "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
  "registrations": [
    {
      "id": "attachment",
      "displayName": "Zotero Attachment",
      "role": "fetcher",
      "mimeTypes": ["application/zotero"],
      "credentialRequirements": [
        {
          "id": "zotero-api-key",
          "kind": "secret",
          "optional": false,
          "label": "Zotero API Key",
          "purpose": "Read your Zotero library and download attachment files."
        }
      ],
      "sync": {
        "configFileName": "zotero-config.json",
        "urlTemplate": "https://api.zotero.org/users/{libraryID}/items/{itemKey}/file",
        "sourceMIMEType": "application/zotero",
        "fields": [
          {"name": "libraryID", "required": true},
          {"name": "attachments", "required": true, "isList": true}
        ],
        "itemValidation": {
          "minimumLength": 8,
          "maximumLength": 8,
          "alphabet": "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        }
      }
    }
  ],
  "capabilities": ["network", "shared-runtime-cache"],
  "files": [
    {"path": "PROVENANCE.md", "digest": "…"},
    {"path": "bin/zotero", "digest": "…"},
    {"path": "bin/zotero-extractor", "digest": "…"}
  ],
  "limits": {
    "maximumInputByteCount": 1048576,
    "maximumMarkdownOutputByteCount": 134217728,
    "maximumDurationMilliseconds": 600000,
    "maximumProgressEventCount": 64
  }
}
```

The registration declares `role: "fetcher"` and NO `kinds`: the package acquires; it never converts. Its claimed input MIME set is exactly the synthetic `application/zotero` source route, and the sync declares the same MIME as its `sourceMIMEType`, so every byteless source the sync creates is one this fetcher claims. The requirement is REQUIRED (`optional: false`) — acquisition cannot proceed without the key, and a missing Keychain value fails the operation with the typed missing-credential state rather than a launch without a key. The sync declaration names the same `zotero-config.json` file the app has always written, so existing configs keep working; `{itemKey}` substitutes one attachment key per item, and the item validation pins the 8-character A–Z0–9 key shape. The output bound is the full 128 MiB host maximum because the attachment file IS the result. The duration bound is 600 s so the first operation on a machine can pay uv's one-time CPython download into the shared runtime cache.

On each request the package reports an explicit result type: `markdown` for Markdown/plain-text attachments (the output IS the product; no format job follows), and `source-bytes` with the true MIME plus the attachment's display filename for PDF/HTML attachments. The host stores the bytes as the source blob, writes the format-job marker in the same transaction, and queues ONE deduped follow-on `.extraction` item so the standard PDF/HTML format route produces the Markdown version.

### Protocol revisions across manifest revisions

The manifest revision and the protocol revision are independent. A manifest-revision-1 package may declare protocol revision 3: a new protocol transport or a new kind does not change the manifest format, and the digest namespace stays tied to the manifest revision. A host that does not support a protocol revision or a kind fails closed at validation. The machine catalog persists each record's manifest revision explicitly; records written before that field existed derive it from the protocol revision, which implied it before protocol revision 3.
- `Docx2md/manifest.json` — Word `.docx` conversion, `runtime` launch with the `bun` command, no capabilities, 120-second duration limit, 32 MiB input and output limits.

Validate any package folder with `swift run extractor-package-tool validate <folder>`. The tool prints the package ID, version, package digest, registration IDs, and protocol revision on success.

Related documents:

- [Extractor script protocol](extractor-script-protocol.md)
- [Dynamic extractor Cordis lifecycle](dynamic-extractor-cordis-lifecycle.md)
- [Extractor package maintainer skill](../skills/extractor-package-maintainer/SKILL.md)
