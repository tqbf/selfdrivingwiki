---
timestamp: 2026-08-26T060000Z
title: Dynamic extractor packages Phase 1 contracts
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 1 contracts

## Progress

Phase 1 defines the extractor package, manifest, protocol, and logical selection contracts.

The extractor types use separate identities for package lineages, exact revisions, registrations, logical references, exact references, activation runs, and requests. Semantic versions use SemVer precedence. Package digests use SHA-256 with canonical lowercase encoding.

Manifest revision 1 supports byte-backed PDF and HTML registrations. It defines direct and runtime launch modes, fixed runtime arguments, package file digests, capabilities, and host operation limits.

Protocol revision 1 uses bounded JSON Lines frames. The sequence validator checks request identity, progress limits, terminal cardinality, output ordering, and the declared output path.

## Manifest validation

The manifest constructor sorts all set-like data before canonical encoding. The package digest includes canonical manifest data and all declared file digests. It excludes file modes and installation paths.

The staged-directory validator rejects hidden undeclared files, links, non-regular files, missing files, changed digests, and normalized path collisions. It checks the manifest file type before it reads the file.

Swift decoding rejects duplicate set members and unknown object fields. This behavior matches the checked JSON Schema contract.

## Selection compatibility

`ExtractionConfig` adds optional `pdfExtractor` and `htmlExtractor` fields. Existing configuration files keep their current defaults and legacy backend fields.

The logical resolver gives an explicit built-in selection priority over the legacy field. It ranks active installed revisions by semantic version and exact revision identity.

An unavailable installed PDF selection uses reviewed local pdf2md. An unavailable installed HTML selection uses tag-based extraction. The resolver preserves the logical selection and returns one typed redacted diagnostic.

## Defects found during review

The first staged validator skipped hidden entries. Hidden undeclared bytes could escape the manifest closure check.

The first manifest decoder converted arrays to sets before it checked duplicates. Swift then accepted data that the schema rejected.

The first protocol sequence did not bind a result to the request output path. The sequence now requires the expected path.

The first selection patch stored logical choices but did not implement precedence or deterministic ranking. A pure resolver now owns this policy.

## Verification

The following checks passed:

- `swift test --filter 'ExtractionConfigTests|ExtractorIdentityTests|ExtractorManifestTests|ExtractorManifestSchemaTests|ExtractorProtocolTests|ExtractorManifestValidatorTests|ExtractorJSONLinesDecoderTests'`
- `swift build`
- LSP diagnostics for the manifest validator, selection resolver, protocol types, and protocol tests

The focused run passed 49 tests in 7 suites. The unrelated `mise.lock` remains untracked and unchanged.
