---
timestamp: 2026-10-19T023748Z
title: Composer buttons show the arrow cursor
branch: fix/issue-1440-composer-cursor
status: complete
---

# Composer buttons show the arrow cursor

## Progress

Issue #1440. In the chat composer, the cursor stayed the text cursor (I-beam)
over the round Send, Stop, and Queue buttons and over the Edit and Cancel
buttons on a queued message. The composer `NSTextView` sets the I-beam. The
borderless SwiftUI buttons next to it did not reset the cursor.

`ChatComposerPaneView` now has one private modifier, `composerButtonPointer()`,
that applies `pointerStyle(.default)` (macOS 15+). Every button in the composer
pane uses it: Send, Stop, Queue, the queued-message Edit and Cancel buttons, and
the attachment-chip remove button. The issue asked for `cursorBehavior`, but
SwiftUI has no modifier with that name. `pointerStyle` is the macOS 15 API for
this. It is declarative, so it has no push/pop stack that can become unbalanced
when a button disappears while the pointer is over it.

## Verification

- `make build` passes.
- `make test` passes.
- Manual check (not done by the agent; the cursor is not visible to automated
  tests): move the pointer from the composer text onto each button. The
  cursor must change to the arrow.
