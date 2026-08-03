# Fix: missing left margin in the Agent / Extraction Queue window transcript

## Symptom
In the standalone Agent / Extraction Queue window (opened from the menu-bar icon), the transcript content runs flush against the left edge — no left margin — while the detail header above it is inset.

## Root cause (verified, file:line)
- `Sources/WikiFS/Queue/ActivityWindowView.swift` — `transcriptContent(for:)` (≈ lines 551-565) hosts `ChatWebView` with only `.frame(maxWidth: .infinity, maxHeight: .infinity)` and **no horizontal padding**.
- The sibling `detailHeader` has `.padding(.horizontal, 16)` (line 539) — so the header is inset 16 but the transcript is inset 0 → the visible mismatch.
- `Sources/WikiFS/Chats/ChatWebView.swift:773` — body CSS is `padding: 10px 12px 10px 0` (left padding deliberately 0). Per PR #457's contract, the **left margin comes from the SwiftUI host** (the CSS 12px right padding only clears the WebView's scrollbar). So the fix belongs at the SwiftUI host, not in CSS.

## Fix
Add `.padding(.horizontal, 16)` to the `ChatWebView` host in `transcriptContent(for:)` in `ActivityWindowView.swift`, so the transcript's left margin matches the `detailHeader` inset (16).

**Do NOT modify `ChatWebView`'s CSS or any other view.** The in-wiki `ChatView` is a separate host with its own 30pt padding and must remain untouched. This is a one-line SwiftUI change scoped to `ActivityWindowView`.

## Acceptance
- `swift build` passes (clean).
- `swift test` (full suite) passes — no regressions (notably `ChatWebViewLinkifyTests` and the autosave-frame tests).
- Visual: the transcript left margin aligns with the header. **Visual verification is deferred to the operator** — you run headless and cannot see the window; just ensure build + tests are green.

## Workflow
1. First commit: copy this plan into `plans/fix-activity-window-left-margin.md` in your worktree.
2. Implement the one-line change.
3. Run `swift build` then `swift test`.
4. Push your branch and open a PR. Do NOT merge to `main`.
