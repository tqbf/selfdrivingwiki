# Extractor script protocol

This document is the normative reference for extractor protocol revision 1. It defines how the host talks to an extractor package script in a separate process.

Sources of truth in code:

- Frame types and sequence rules: `Sources/WikiFSTypes/Extractor/ExtractorProtocol.swift`
- Host policy limits: `Sources/WikiFSTypes/Extractor/ExtractorManifest.swift` (`ExtractorHostLimits`)
- Process executor: `Sources/WikiFSCore/Extractor/ManagedExtractorProcessExecutor.swift`
- JSON Lines decoding: `Sources/WikiFSCore/Extractor/ExtractorJSONLinesDecoder.swift`
- Process-group launch and termination: `Sources/WikiFSCore/Extractor/RaceFreeProcessGroupRunner.swift`

## Model

Protocol revision 1 is one-shot. The host starts one process per extraction request. The package converts one input file to one Markdown result.

- The host writes one request frame to standard input and then closes standard input.
- The package writes zero or more progress and diagnostic frames to standard output, then exactly one terminal frame.
- A terminal frame is a result frame or a failure frame.
- Standard output carries protocol frames only. Standard error carries bounded unstructured diagnostics only.
- The exchange uses JSON Lines. Each frame is one JSON object followed by a newline.

Packages do not run as Swift, do not load as modules, and never see a `CordisContext`. The host starts them with `posix_spawn` in a dedicated process group. The host does not use a shell.

## Limits

`ExtractorHostLimits` fixes these maxima. A manifest can declare smaller limits, never larger ones.

| Quantity | Maximum |
| --- | --- |
| Frame size | 64 KiB |
| Standard error retained by the host | 64 KiB |
| Input file | 128 MiB |
| Markdown result file | 128 MiB |
| Progress events per operation | 10,000 |
| Operation duration | 30 minutes |
| Request original filename | 1,024 bytes |

## Request frame

The host encodes one `ExtractorProtocolRequest` as JSON, appends a newline, writes it to standard input, and closes standard input.

| Field | Type | Rules |
| --- | --- | --- |
| `requestID` | UUID string | Identifies the operation. Every frame must repeat it. |
| `protocolRevision` | integer | Must be `1`. |
| `kind` | string | `pdf` or `html`. |
| `mimeType` | string | Normalized lowercase MIME type. |
| `originalFilename` | string | 1 to 1,024 bytes, no NUL. |
| `inputTransport` | string | `operation-file` in revision 1. |
| `inputPath` | string | Package-relative path to the input file. |
| `outputPath` | string | Package-relative path for the Markdown result. Must differ from `inputPath`. |
| `deadlineMillisecondsSince1970` | integer | Positive. The host cancels the operation at this deadline. |

Example request:

```json
{"requestID":"1b0d...","protocolRevision":1,"kind":"html","mimeType":"text/html","originalFilename":"article.html","inputTransport":"operation-file","inputPath":"input/source.html","outputPath":"output/result.md","deadlineMillisecondsSince1970":1735689600000}
```

Content bytes never travel in JSON. The host puts the input file inside a private operation directory that it creates with owner-only permissions (`0700`). The package reads `inputPath` and writes `outputPath` inside that directory.

## Package frames

Every package frame uses one envelope:

```json
{"kind":"progress|diagnostic|result|failure","payload":{...}}
```

### Progress frame

| Field | Type | Rules |
| --- | --- | --- |
| `requestID` | UUID string | Must match the request. |
| `completedUnitCount` | integer, optional | At least 0. |
| `totalUnitCount` | integer, optional | At least 1. `completedUnitCount` must not exceed it. |
| `message` | string, optional | 1 to 1,024 bytes, no NUL. |

### Diagnostic frame

| Field | Type | Rules |
| --- | --- | --- |
| `requestID` | UUID string | Must match the request. |
| `message` | string | 1 to 4,096 bytes, no NUL. |

### Result frame

| Field | Type | Rules |
| --- | --- | --- |
| `requestID` | UUID string | Must match the request. |
| `outputPath` | string | Must equal the request `outputPath`. |
| `markdownByteCount` | integer | 0 to 128 MiB. Must match the bytes the package wrote. |
| `warnings` | array of strings, optional | At most 128 entries, each 1 to 1,024 bytes. |
| `metadata` | object, optional | Package-reported tool and model facts. |
| `articleMetadata` | object, optional | Article facts for HTML packages. |

`metadata` fields, each optional and at most 256 bytes: `toolName`, `toolVersion`, `modelName`, `modelVersion`. The host records these as provenance. It does not treat a package version as a model version.

`articleMetadata` fields: `title`, `author`, `description`, `published` (each an optional string of at most 1,024 bytes) and `wordCount` (an optional integer from 0 to 10,000,000). The reviewed Defuddle package uses these to carry article metadata end to end.

### Failure frame

| Field | Type | Rules |
| --- | --- | --- |
| `requestID` | UUID string | Must match the request. |
| `cause` | string | One value from the table below. |
| `message` | string | 1 to 4,096 bytes, no NUL. |
| `warnings` | array of strings, optional | Same rules as the result frame. |
| `metadata` | object, optional | Same rules as the result frame. |

### Failure causes

| Value | Meaning | Set by |
| --- | --- | --- |
| `unsupported-input` | The input does not match the registration. | Package |
| `invalid-request` | The request is malformed for the package. | Package |
| `missing-runtime` | A runtime command is absent. | Host |
| `setup` | Dependency or model setup failed. | Package |
| `timeout` | The operation passed its deadline or duration limit. | Host |
| `cancellation` | The user or the host canceled the operation. | Host |
| `process-termination` | The process exited nonzero or died from a signal. | Host |
| `output-limit` | Output exceeded a host limit. | Host |
| `malformed-protocol` | Standard output broke the frame rules. | Host |
| `extraction-failure` | The conversion failed for a content reason. | Package |

## Sequence rules

`ExtractorProtocolSequence` enforces these rules on the frame stream:

1. Every frame must carry the request `requestID`.
2. Progress events must not exceed the manifest limit.
3. The stream must contain exactly one terminal frame.
4. A result frame must name the expected `outputPath`.
5. No frame may follow the terminal frame.
6. At end of stream, a terminal frame must exist. Otherwise the operation fails.

The host decodes standard output continuously with `ExtractorJSONLinesDecoder`. Malformed UTF-8 or malformed JSON is a protocol failure. When the host detects a protocol failure, it requests termination of the verified process group and fails the operation. A nonzero exit code or a signal after a valid terminal frame is still a `process-termination` failure. The host requires exit code 0.

## Environment contract

The host gives the process a fixed environment. It does not forward the parent environment, credentials, API tokens, or wiki database paths.

| Variable | Value |
| --- | --- |
| `HOME` | Operation-private home directory |
| `TMPDIR` | Operation-private temporary directory |
| `XDG_CACHE_HOME` | Package-private cache directory |
| `LANG`, `LC_ALL` | `C.UTF-8` |
| `WIKI_EXTRACTOR_REQUEST_ID` | The request UUID |
| `WIKI_EXTRACTOR_PROTOCOL_REVISION` | The protocol revision |
| `WIKI_EXTRACTOR_SHARED_RUNTIME_CACHE` | Shared cache path. Present only when the manifest declares `shared-runtime-cache`. |
| `WIKI_EXTRACTOR_SHARED_MODEL_CACHE` | Shared model cache path. Present only when the manifest declares `model-download`. |

The current working directory is the operation root.

## Deadline and cancellation

The host owns time. The effective timeout is the smaller of the manifest duration limit and the remaining time to the request deadline. When the timeout passes or the host cancels the task, the host sends `SIGTERM` to the verified process group, waits a one-second grace period, and then sends `SIGKILL` to the same group. The host rechecks the executable identity immediately before spawn and refuses to launch changed bytes.

## Host rejections

The host fails the operation, and the package loses the selection, when any of these happen:

- A frame violates the byte, count, or content rules.
- Standard output carries data that is not a valid frame.
- A frame names another request.
- Two terminal frames appear, or none appears.
- Output appears after the terminal frame.
- The process writes past the standard-output limit.
- The process exits nonzero, dies from a signal, or fails to appear.

## Compatibility

Revision 1 is the only protocol revision. The manifest declares the revision the package speaks, and the request repeats it. A mismatch fails the operation before spawn. Future revisions must keep this document updated with a migration note in `docs/architecture/extractor-package-manifest.md`.

Related documents:

- [Extractor package manifest](extractor-package-manifest.md)
- [Dynamic extractor Cordis lifecycle](dynamic-extractor-cordis-lifecycle.md)
- [Extractor packages (user guide)](../user-guide/extractor-packages.md)
