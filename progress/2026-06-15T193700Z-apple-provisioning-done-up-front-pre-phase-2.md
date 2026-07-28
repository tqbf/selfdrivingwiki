---
timestamp: 2026-06-15T193700Z
title: "2026-06-15 — Apple provisioning done up front (pre-Phase 2)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Apple provisioning done up front (pre-Phase 2)

## Progress


Per the user's call, knocked out the File Provider / App Group portal setup
*before* starting feature work, to de-risk Phase 2. Full detail + verified
strings in `plans/signing.md`.

- Apple Development cert installed: `Apple Development: Thomas Ptacek
  (7F2QE7P59D)` — already matches `DEV_IDENTITY` in the `Makefile`.
- This Mac registered as a dev device (`00006050-00190839016B401C`).
- App IDs created: `org.sockpuppet.WikiFS`, `org.sockpuppet.WikiFS.FileProvider`
  (both with App Groups capability).
- **App Group is `group.org.sockpuppet.wiki`** — NOT `…wikifs`. The `…wikifs`
  group got fouled up in the portal; adopted the working `…wiki` name rather
  than redo + regenerate profiles. Docs updated to match. DB will live at
  `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`.
- Two macOS App Development profiles downloaded to `signing/` (gitignored),
  decoded + verified: team `KK7E9G89GW`, this device included, expire
  2027-06-15, authorize the exact entitlements recorded in `plans/signing.md`.
- Remaining signing work (embed profiles, inside-out codesign, `make install`
  loop) is wired in Phase 2.

## Verification

Historical verification remains in the progress record above.
