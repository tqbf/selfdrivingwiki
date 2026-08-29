---
timestamp: 2026-08-28T130000Z
title: PR 2: extractor credential declarations + authorization (#1165)
branch: feature/extractor-credential-authorization
status: complete
---

# PR 2: extractor credential declarations + authorization (#1165)

## Progress

Issue #1159 PR 2, branch `feature/extractor-credential-authorization`
(parent #1164, exact head `58614378`).

- Manifest revision 2: registration-scoped `credentialRequirements`
  (normalized, bounded, validated); revision 1 decoding rejects the key and
  keeps canonical bytes/digests byte-for-byte; manifest-wide requirement-ID
  uniqueness. Fixture `invalid/unsupported-revision.json` moved to revision 3
  because revision 2 is now supported.
- `ExtractorCredentialRequirementFingerprint` over lineage + registration
  scope + normalized contract; scope-parts derivation shared by Settings and
  the writer.
- Durable secret-free authorization store at
  `<App Group>/credentials/extractor-credential-authorizations.json`:
  read-only reader (app + daemon), app-only writer (role gate + flock +
  atomic replace + 0600); grants never transfer lineages; removal never
  deletes.
- Pure `ExtractorCredentialAuthorizationResolver` (admission, exact
  declaration, fingerprint, configured state → authorized / unauthorized /
  missingCredential).
- Settings: Package Credentials section, Authorize / Change Credential /
  Revoke with the inheritance rule stated BEFORE approval, app-owned
  closures, derived accessibility identifiers.

## Verification

17 core + 4 hosted (inheritance-rule copy, secret-free summaries,
  writer only in app wiring). Gates: make lint/build/test (3945).
