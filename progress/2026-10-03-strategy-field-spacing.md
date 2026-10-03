---
date: 2026-10-03
status: complete
scope: strategy editor resize spacing
---

# Strategy field spacing

## Progress

A saved multi-line strategy made the gap below Display Name grow with the window height.
`ViewThatFits` selected the compact layout because the editor's ideal height depended on its content.
The header scroll view used the extra height while the instructions editor stayed at 240 points.

The editor now uses its existing minimum height as its ideal height.
The instructions editor still expands, and the controls stay at the bottom.
No fonts, draft behavior, or persistence changed.

## Verification

The hosted resize test now saves a 40-line strategy before it mounts the real view.
Before the fix, the test failed with five issues.
After the fix, the measured gap stayed at 62 points across heights 650, 750, 900, and 1050.
The editor heights were 352.5, 452.5, 602.5, and 752.5 points.
The compact 480-point window retained the editor minimum height and bottom controls.

- Hosted resize test passed. Log: `tmp/strategy-resize-final.log`.
- Hosted save/cancel/reset test passed. Log: `tmp/strategy-savecancel-smoke.log`.
- `make build` passed and signed the app. Log: `tmp/strategy-make-build.log`.
- Pre-fix failure log: `tmp/strategy-resize-prefix-failure.log`.

These checks do not resolve the template-menu workflow blocker or the feature's remaining release-validation decisions.
