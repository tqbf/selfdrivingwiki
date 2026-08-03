---
timestamp: 2026-06-16T152345Z
title: "2026-06-16 — URL ingest fix: share-link normalization + content sniffing"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — URL ingest fix: share-link normalization + content sniffing

## Progress


Branch `feature/url-ingest`. A real-world test exposed a gap: pasting a **Dropbox
share link** to a PDF stored the Dropbox HTML *preview page* (converted to junk
markdown) instead of the PDF. File-share hosts (Dropbox, Google Drive, OneDrive)
hand non-browser clients a JS interstitial unless you hit the direct-download host
— and Dropbox serves HTML for BOTH `dl=0` and `dl=1`. Two pure, tested fixes:

- **`ShareLinkNormalizer` (new, `WikiFSCore`)** — `normalize(_ url:) -> URL` with a
  list of provider `Rule`s. **Dropbox:** host `www.dropbox.com`/`dropbox.com` →
  `dl.dropboxusercontent.com`, preserving path + query (so the `.pdf` filename in
  the path and the `rlkey`/`e` auth params survive) — the verified rewrite that
  returns raw `%PDF` bytes. Conservative: an unrecognized URL passes through
  byte-for-byte. Google Drive / OneDrive shapes are stubbed in comments for trivial
  add-later. **Wired into `URLSessionFetcher.fetch`** (normalizes BEFORE the request),
  so every production fetch — `ingest` and `WikiStoreModel.ingestURL` — benefits.
- **Content sniffing in `URLIngestService.plan(for:)`** — `sniffContentType(_ data:)
  -> String?` reads leading magic numbers (`%PDF`→pdf, `\x89PNG`→png, `\xFF\xD8\xFF`
  →jpeg, `GIF8`→gif, `PK\x03\x04`→zip). When the declared type is ambiguous
  (`text/html`, missing, or `application/octet-stream` — see `shouldSniff`) but the
  bytes are clearly a known binary, store them VERBATIM as the sniffed type instead
  of running HTML→Markdown. A specific declared type (`application/pdf`, …) is
  trusted as-is. This is the backstop if an interstitial ever slips past the
  normalizer.

**Tests.** +5 `ShareLinkNormalizerTests` (www/bare-host rewrite preserves
path+query+filename; non-share URL unchanged; case-insensitive; no double-rewrite),
+6 in `URLIngestServiceTests` (html-labeled-%PDF→`.pdf` byte-identical;
octet-stream-PNG→`.png`; genuine HTML still→markdown; real PDF still→`.pdf`; the
`sniffContentType`/`shouldSniff` tables). `make test` → **300/300** green; `make`
clean signed bundle. The original failing URL
(`www.dropbox.com/scl/fi/…/CPP_behaviorgen.pdf?…&dl=0`) now normalizes to
`dl.dropboxusercontent.com`, fetches `%PDF` bytes, and stores `CPP_behaviorgen.pdf`.

## Verification

Historical verification remains in the progress record above.
