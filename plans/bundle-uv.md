# Bundle `uv` (like `bun`) so pdf2md extraction is self-contained

Issue: #766

## Problem
The app bundles the `pdf2md` *script* (a PEP 723 inline script whose shebang is
`#!/usr/bin/env -S uv run --script`) but NOT `uv` — the runtime it needs to
bootstrap its own Python + dependencies. `PdfExtractionService` falls back to a
PATH search (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) and, if uv
isn't on the system, degrades to the agent Read tool (raw PDF, no extraction).

## Solution
Mirror the existing `bun` bundling pattern (single static binary copied into
`Contents/Helpers/` and codesigned inside-out). `uv` (astral-sh/uv) is the same
shape — a single self-contained binary.

## Changes

### 1. `build.sh` — bundle uv (mirror bun block at ~L147-160)
Add a `UV_SRC` resolution + copy block placed right after the bun block:
- Resolve `UV_SRC` from `UV_INSTALL` → `~/.local/bin/uv` → `command -v uv`.
- `cp` to `${HELPERS_DIR}/uv`.
- Fail with an install hint if absent (REQUIRED, matching bun's hard gate).
- Do NOT touch the bun block — separate binary, separate block.

### 2. `build.sh` — sign the bundled uv (~L391-426)
Codesign `${HELPERS_DIR}/uv` inside-out (before the outer app), in BOTH the
real-identity section and the ad-hoc fallback (`codesign --force --sign -`),
mirroring how bun is signed.

### 3. `Sources/WikiFS/Sources/PdfExtractionService.swift` (`uvSearchPATH`, L60-66)
Prepend the bundled Helpers directory (resolved via `HelpersLocation.wikictlDirectory`,
which already finds `Contents/Helpers` in the signed bundle and `build/` in dev)
to `uvSearchPATH`, so the pdf2md shebang finds the bundled `uv` FIRST. Keep the
existing system-uv fallback paths (`~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`) — they remain a fallback if the bundled uv is absent.

## Guardrails
- uv is a single static binary — no venv or Python to manage.
- Do NOT change the pdf2md script itself.
- Do NOT remove the existing system-uv fallback paths.
- Bundled uv goes FIRST in the PATH.
- Bun bundling must remain unaffected (separate binary, separate block).
- No `print` (DebugLog only); no bare `try?`.

## Build / test
- `make build` — should bundle uv alongside bun; verify `Helpers/uv` exists.
- `make test`.
- Push branch, open PR with `Closes #766`. Do NOT merge to main.
