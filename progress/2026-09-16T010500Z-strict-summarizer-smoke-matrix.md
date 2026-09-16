---
timestamp: 2026-09-16T010500Z
title: Strict summarizer smoke matrix (#1279) — all adapters fail; two root causes
branch: main (validation only; no product code changed)
status: complete
---

# Strict summarizer smoke matrix (#1279) — all adapters fail; two root causes

## Progress

Ran the issue #1279 matrix end-to-end against a fresh build of `main`
(`1117-ba4e1b77`, includes the #1278 strict tier). Every cell fails; results
and evidence are recorded in the issue comment
(https://github.com/tqbf/selfdrivingwiki/issues/1279#issuecomment-5690189243).

Findings, in order of importance:

1. **`bun x` adapters cannot run under the strict summarizer tier.** bun 1.4.0
   stages the `bunx-501-@pkg` project under the child's `TMPDIR`
   (`<scratch>/.tmp` after the launcher relocation) and execs
   `dist/index.js` from that staging directory. The strict trailer's
   `(deny process-exec* (subpath "SCRATCH_DIR"))` denies that exec. This hits
   the shipped default (`bun x @agentclientprotocol/claude-agent-acp`) and,
   through `ACPBackend`'s npx→bun canonicalization, both `npx` providers
   (codex-acp, gemini-cli) — warm cache as well as cold. Captured `sandboxd`
   denials name the adapter in each case. Harness bisect (byte-matched
   profile, real binaries) isolates the W^X scratch pair as the sole killer;
   the pivot-exec and credential-read deny groups are individually harmless.
   Relocating the child `TMPDIR` to exec-allowed provider-home land
   (`~/.bun/tmp-…`) lets the adapter survive the FULL strict profile — the
   candidate design fix when the strict tier is reopened.
2. **`uvx` adapters fail on a missing `providerHomeSubpaths` mapping.**
   `~/.cache/uv` (and `~/.local/share/uv`) writes are denied under both
   fences; `uvx` exits 2 at cache init ("Operation not permitted"). This is
   the documented adaptation signal — the table needs a `uv`/`uvx` row.
3. **Degradation-contract gap (nil path).** `MessageSummarizer.oneShotReply`
   returns nil on launch failure, and `DaemonChatHost.runModelSummarization`
   treats nil as "skip" (`guard … else { continue }`), so the truncation
   fallback in the `catch` branch never runs. Rows stayed unsummarized in
   every matrix run, contrary to the strict-tier failure contract.
4. **`sandboxd` violation records reach `log show` minutes late** on macOS
   26.6.2. The issue's `--last 5m` recipe can report "no denials" for a run
   that had them; capture windows must extend past the run by several
   minutes.
5. **The shipped default `bun x …` command does not resolve from the GUI
   daemon** (`noAgentConfigured`): the launcher resolves first tokens against
   a PATH that lacks mise's bun directory; only the npx→bun canonicalization
   path resolves bun via a login shell. Row 1 was run with an absolute bun
   path.
6. **`build.sh` could not package a bootable app from current `main`** under
   the Swift 6.4 toolchain: SwiftPM now emits macOS-style resource bundles
   (`…bundle/Contents/Resources/Prompts`), while `build.sh` staged the old
   flat layout, so no module bundles shipped and the app trap-crashed at
   launch (`resource_bundle_accessor.swift:44` via
   `ProductionProfileResolver`). Fixed locally (both layouts + staging all
   non-test module bundles into app/appex/wikid); PR follows.

Method notes for reproduction: chats were driven through the real app (the
omnibox focus does not accept synthetic input; the working path is sidebar
Chats tab → New Chat button → the autofocused composer, with the new chat row
verified in SQLite before typing). The scratch wiki `Sandbox Smoke 1279`
(`01M2K6KZRMXKQAWHPZTGXE29QJ`) holds the eight evidence chats.
`agent-providers.json` was backed up to `agent-providers.json.pre-1279` and
restored bit-for-bit after the runs; bun/npm/uv caches were moved aside for
cold cells and restored. Harness scripts live in the (gitignored)
`tmp/1279/`.

## Verification

- Eight matrix cells executed (4 adapters × cold/warm) in the scratch wiki;
  per-cell chat IDs, timestamps, and denial excerpts in the issue comment.
- Harness bisect: read-only base alone → adapter alive; base + strict trailer
  → dead; only the `SCRATCH_DIR` W^X pair reproduces the kill; full strict +
  `TMPDIR` at `~/.bun/tmp-…` → adapter alive (bun, warm cache, real spawn of
  `bun x @agentclientprotocol/codex-acp@1.1.7`).
- Config restore verified: provider list, enabled/default flags, stage pins,
  and the claude command all match the pre-run snapshot; caches back in
  place; app relaunched on the restored config.
- No repo code changed on `main`; the `build.sh` fix is uncommitted working
  tree (PR to follow).
