---
timestamp: 2026-09-19T180000Z
title: Chats section header aligns with the other sidebar sections
branch: fix/chats-header-alignment
status: complete
---

# Chats section header aligns with the other sidebar sections

## Progress

The Chats section's title sat slightly higher than the Pages, Sources, and
Bookmarks titles. Two divergences caused it:

1. The `+` button was a bare symbol image (`.borderless` + `.fixedSize`)
   with no frame, so the header row was several points shorter than the
   sibling rows whose `headerButton` helper enforces a 24×24 icon frame.
2. The header `HStack` lacked the siblings' `spacing: 2`.

The header now uses the same 24×24 `headerButton` treatment and `spacing: 2`
as the other sections, so all four sidebar titles share one row height and
baseline. The Chats search bar's leading padding also moved from 12 to 4 to
match the sibling search rows. No behavior change.

## Verification

- `make build` and `make test` — green.
- Visual check: the Chats title's baseline and row height now match
  Pages / Sources / Bookmarks.
