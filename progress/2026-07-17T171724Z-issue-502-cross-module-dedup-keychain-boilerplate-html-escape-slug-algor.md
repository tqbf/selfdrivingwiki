---
timestamp: 2026-07-17T171724Z
title: "2026-07-17 — Issue #502: Cross-module dedup — keychain boilerplate, HTML escape, slug algorithm (branch `cross-module-dedup`, PR #504)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Issue #502: Cross-module dedup — keychain boilerplate, HTML escape, slug algorithm (branch `cross-module-dedup`, PR #504)

## Progress


**Shipped (PR #504, open — NOT merged).** Three cross-module dedup fixes; net
**−122 lines** of duplicated boilerplate (8 files modified, 2 new shared modules).

**L1 — Keychain `SecItem` boilerplate (3 stores → 1).** New
`Sources/WikiFSCore/KeychainSecretStore.swift` centralizes the generic-password
query/add/update/delete mechanics (`read(service:account:)`,
`write(service:account:value:error:)`). `KeychainZoteroCredentialStore`,
`KeychainACPCredentialStore`, `KeychainExtractionCredentialStore` now delegate;
each keeps only its `service`/`account` mapping and its own typed error. ACP's
pre-existing local `read`/`write` helpers removed. `write` takes an
`error: (String, OSStatus) -> Error` factory so each store throws its own
`*KeychainError` with the exact `operation`/`status` formatting it always had —
behavior preserved.

**L2 — byte-identical HTML escape.** Added `HTMLEntities.escapeHTML(_:)` (enum
made `public` so the `WikiFS` target can reach it; `decode` stays module-
internal). `ChatWebView.escape` and `MarkdownHTMLRenderer.escape` now delegate;
the `escapeAttribute`/`escapePreservingBreaks`/`htmlAttributeEscape` wrappers
are unchanged. `HTMLMarkdownRenderer.escapeInline` (markdown `[`/`]`) is
different logic — left alone.

**L3 — duplicated slug algorithm.** New `Sources/WikiFSCore/SlugUtils.swift`
holds the shared `slugBase(_:)` normalization (lowercase → whitespace→`-` →
keep letters/numbers/`-` → collapse). `AnchorBlock.makeSlug` and
`SQLiteWikiStore.slugify` delegate, keeping their own fallback
(`"heading"`/`"untitled"`) and suffix logic. `slugBase` matches `makeSlug`'s
Unicode-permissive behavior, so the heading-anchor/`resolveAnchor` path is
byte-identical; `slugify` now also keeps non-ASCII letters/whitespace (existing
DB slugs read verbatim; only new/renamed titles change). `PodcastEpisodeURL.slug`
is path-based — deliberately separate. Note: the issue assumed the two slugs
were "the same algorithm" — they differed subtly (ASCII-only vs Unicode).

**Build/tests:** `swift build` clean; fast tier **2444 tests/210 suites passed**;
targeted `slugifyStripsPunctuationAndCollapsesDashes` (in the skipped
`SQLiteWikiStoreTests`) passes with the changed `slugify`.

## Verification

Historical verification remains in the progress record above.
