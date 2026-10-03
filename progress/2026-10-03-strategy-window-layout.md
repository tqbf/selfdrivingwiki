---
timestamp: 2026-10-03T120000Z
title: Strategy editor window layout
branch: feature/wiki-strategies-cumulative-ingestion
status: complete
---

# Strategy editor window layout

## Progress

The operator requested a taller instructions editor and bottom-anchored controls.
The editor now fills the remaining window height. Long instructions scroll inside the text editor.
A divider separates the bottom action row from the editor.
Compact windows scroll the header fields rather than move the actions offscreen.
Strategy persistence and draft behavior are unchanged.

## Verification

`make build` passed and assembled the signed application.
The hosted resize test passed at window heights of 650, 900, and 1050 points.
It verifies editor growth and stable bottom action placement through real AppKit view measurements.
The five existing hosted save, switch, conflict, page-preservation, and appearance tests passed.
The seven-test suite still fails only the known template-menu interaction scenario.
That earlier validation blocker remains unresolved. This layout change does not claim to resolve the saved goal's review or rubric blockers.
