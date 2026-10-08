---
timestamp: 2026-10-08T160000Z
title: Chat cancellation ownership
branch: bugfix/chat-cancellation-state-machine
status: active
---

# Chat cancellation ownership

## Progress

The implementation is in progress on `bugfix/chat-cancellation-state-machine`.

The domain now carries typed cancellation events, retryable cancellation and cleanup attentions, and a terminal continuation policy.
Cancel stops the current turn and continues durable followers in FIFO order.
Shutdown retains followers and does not promote or dispatch them.
The controller uses one internal dispatch-ownership value instead of separate lifecycle flags.
The store cancels an unclaimed queued row atomically and emits one resource event after commit.
Each host chat obtains its own launcher and runtime through an injected runtime factory.
The app projects cancellation from the server active-turn state and drains its local queue only when no daemon work remains.

## Verification

Focused suites pass for the chat domain, sync wire, client reducer, store persistence, store emission, run state, cancellation gate, and the daemon chat controller.
`make test` passes the full default graph, and bare `swift build` and `swift test` also pass.
An independent review in the DeepSeek model family found no double-terminal-commit path. It found three defects, all fixed and covered: shutdown read the claim after taking shutdown ownership, so a claimed active turn was never durably settled; a failed runtime close advertised a retry that nothing ran; and a released preparation dropped a pending drain. Continuous integration then caught a pre-existing race in the transport-close recovery test, which now waits for the close before submitting.

Pull request: #1384. All four continuous integration jobs pass.

The operator's live chat database was not queried or modified.
See `plans/chat-cancellation-state-machine.md` for the state table, effect ownership, and the same-bundle sync contract.
