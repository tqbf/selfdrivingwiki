# Extractor package manifest

This document is the normative reference for the extractor package manifest, revision 1, and for the package digest.

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

| Field | Type | Rules |
| --- | --- | --- |
| `id` | string | 1 to 64 characters, lowercase ASCII letters, digits, hyphens. |
| `displayName` | string | 1 to 128 bytes. |
| `kinds` | array | Nonempty subset of `pdf`, `html`, and `docx`. |
| `mimeTypes` | array | Nonempty set of normalized lowercase MIME types. |
| `filenameExtensions` | array, optional | Lowercase ASCII letters and digits, no leading dot, at most 32 characters. |

Duplicate values inside one registration are rejected. Duplicate registration IDs in one manifest are rejected.

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

`extraction-config.json` stores one generic selection table: `routeExtractors`, a sorted array of route records. Each record names a typed extraction route (kind plus MIME type) and a version-free reference — a host adapter identity, an installed package lineage, or an explicit no-default value. The route supplies the input format; the reference names only the implementation.

One-time migration. The retired `backend`, `htmlBackend`, `pdfExtractor`, and `htmlExtractor` keys are decode-only inputs. The decoder adopts each retired value into the matching route record when no record claims that route: `backend` values become host references (`localPdf2md` leaves the record absent, because the bundled default supplies it), and `htmlBackend` values become host references. Encode never writes the retired keys again.

Defaults. Fresh installs and record-less routes resolve through the bundled default-route policy (`default-routes.json`): the PDF route defaults to the reviewed pdf2md lineage, and the DOCX route to the reviewed docx2md lineage (`org.selfdrivingwiki.docx2md`, registration `document`). HTML has no shipped default — the user picks an extractor, and the built-in tag-based adapter is the execution floor. An explicit no-default record disables the shipped default for its route.

Failure posture. An installed selection with no compatible active registration keeps its saved identity, emits one redacted diagnostic, and fails closed. The app never silently selects a different third-party package.

Legacy host identities keep working. A migrated `localPdf2md`, `doclingServe`, or `defuddle` host reference maps to its reviewed package lineage (`org.selfdrivingwiki.pdf2md` / `org.selfdrivingwiki.docling-serve`, registration `document`; `org.selfdrivingwiki.defuddle`, registration `article`) when that lineage is active, and fails closed when it is not.

## Worked examples

The reviewed packages in `ExtractorPackages/` are complete reviewed packages:

- `Defuddle/manifest.json` — HTML article extraction, `runtime` launch with the `bun` command, no capabilities, 120-second duration limit, 32 MiB input and output limits.
- `Pdf2md/manifest.json` — PDF conversion, `runtime` launch with the `uv` command and `run --script` arguments, `network`, `shared-runtime-cache`, and `model-download` capabilities, 30-minute duration limit, 128 MiB input limit.
- `DoclingServe/manifest.json` — PDF conversion through a self-hosted Docling Serve, `direct` launch, manifest revision 2 with an optional `api-token` credential requirement, `network` capability.
- `Docx2md/manifest.json` — Word `.docx` conversion, `runtime` launch with the `bun` command, no capabilities, 120-second duration limit, 32 MiB input and output limits.

Validate any package folder with `swift run extractor-package-tool validate <folder>`. The tool prints the package ID, version, package digest, registration IDs, and protocol revision on success.

Related documents:

- [Extractor script protocol](extractor-script-protocol.md)
- [Dynamic extractor Cordis lifecycle](dynamic-extractor-cordis-lifecycle.md)
- [Extractor package maintainer skill](../skills/extractor-package-maintainer/SKILL.md)
