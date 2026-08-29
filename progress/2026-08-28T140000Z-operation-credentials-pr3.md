---
timestamp: 2026-08-28T140000Z
title: PR 3: operation-scoped credential injection (#1166)
branch: feature/extractor-operation-credentials
status: complete
---

# PR 3: operation-scoped credential injection (#1166)

## Progress

Issue #1159 PR 3, branch `feature/extractor-operation-credentials`
(parent #1165, exact head `2033b6e2`).

- Protocol revision 2 requests: optional RELATIVE paths for a private
  credential input file and a public operation-configuration file; values
  never ride stdin JSON or environment; revision 1 requests reject the keys.
- `ExtractorCredentialInputEnvelope` (bounded, declared-requirements-only,
  non-empty values) and `ExtractorOperationConfiguration` (closed
  endpoint/timeout field set).
- `ExtractorOperationCredentialResolver` host service in app AND daemon
  composition: rechecks admission + catalog, reloads authorizations,
  validates fingerprints, resolves each authorized reference once; required
  missing values block with a bounded error; optional absent values are
  omitted; a declaring package without a resolver fails closed.
- `PreparedProcessOperation.execute`: per-execute resolution (rotation /
  revocation / removal / reinstall affect the NEXT call), 0400 O_EXCL
  credential file verified before launch, request subdirectories deleted on
  every terminal path, `ExtractorSecretRedactor` applied to progress,
  failure frames, and mapped errors.
- Revision 1 semantics unchanged (no resolution, no request paths).

## Verification

12 targeted (paths, envelopes, redaction, injection, cleanup,
  rotation, revocation, fail-closed, revision-1 shape). Gates: make
  lint/build/test (3957). Superseded pins updated: protocol revision 2 valid
  (identity test), generated-plugin dependency count 6 → 7.
