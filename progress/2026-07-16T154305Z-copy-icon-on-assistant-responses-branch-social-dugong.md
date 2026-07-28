---
timestamp: 2026-07-16T154305Z
title: "2026-07-16 — Copy icon on assistant responses (branch `social-dugong`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — Copy icon on assistant responses (branch `social-dugong`)

## Progress


**Implemented.** Replaced the text "Copy" button on assistant chat bubbles
with a lucide `Copy` SVG icon, matching Paseo's `TurnCopyButton` pattern.

- Lucide `Copy` SVG icon (15×15, `currentColor` stroke) replaces text label.
- On click, swaps to green `Check` icon for 1.5s (Paseo parity).
- CSS: transparent bg, `--code-bg` on hover, `currentColor` tint.
- JS handler swaps `innerHTML` between copy/check SVGs.

## Verification

Historical verification remains in the progress record above.
