## Summary

Stop committing derived codegen artifacts to git. `GeneratedVersion.swift` (git state → Swift) and `GeneratedPrompts.swift` (prompts/*.md → Swift) were checked-in "derived artifacts," but the version file embeds the git SHA + commit count — so it drifted on **every commit**, producing constant `git add` noise, spurious diffs, and merge conflicts on a file whose content is, by definition, derived from git itself.

Both files are now **gitignored** (kept on disk locally, regenerated at build time). The build pipeline already regenerates them — no manual `git add` step is needed anymore.

## Changes

**Build-time generation (no drift, no commits):**
- `git rm --cached` both `Generated*.swift` files (working copies kept on disk).
- `.gitignore` — added both paths with an explanatory block.
- `Makefile` — dropped the `check-prompts` / `check-version-gen` drift-gate targets (+ `.PHONY` + help entries); these are now meaningless since there's no committed file to drift against. The existing prereqs (`version`/`prompts` run before `build`/`check`/`test`/`release`) are unchanged, so `make build/check/test` always produce fresh files.
- `.github/workflows/ci.yml` — replaced the `make check-prompts` drift step with `make version prompts` before `swift build` in **both** Swift jobs (`swift` + `swift-integration`).

**Doc updates:**
- `AGENTS.md`, `PLAN.md`, `plans/phase-6-pinning.md` — updated prose that claimed the files were checked-in / that CI fails on drift.
- `tools/promptgen/main.swift`, `tools/versiongen/main.swift` — updated header comments.
- `PROGRESS.md` — entry documenting the change + rationale.

## How it works

| File | Source of truth | Regen mechanism |
|---|---|---|
| `GeneratedVersion.swift` | git state (SHA + commit count) | `make version` — prereq of build/check/test/release |
| `GeneratedPrompts.swift` | `prompts/*.md` | `make prompts` — prereq of build/check/test/release |

CI runs `make version prompts` before `swift build`, so the gitignored files exist before compilation.

## Tradeoff

Bare `swift build` on a fresh clone no longer finds the gitignored files until `make version prompts` runs. This matches the **existing** documented contract for prompts ("run `make prompts` after editing a .md if you're driving swift directly"). The canonical paths (`make build`/`check`/`test`) are unaffected.

## Validation

- `make check` — regenerated `GeneratedPrompts.swift`, compiled it (`Compiling WikiFSCore GeneratedPrompts.swift` → Build complete! 12.70s).
- `git status` afterward shows the generated files only as the staged `D` deletion — **no `M`/modified flag, no `git add` needed** (the file is now gitignored).
- Verified both `check-prompts` and `check-version-gen` targets are fully removed from the Makefile.

## Alternatives considered

A SwiftPM **BuildToolPlugin** would auto-regenerate on every `swift build` (CI included, no pre-step), fully eliminating the "bare `swift build` needs a make pre-step" tradeoff. It was deemed more than this change requires (new plugin target + plugin-sandbox/git-subprocess caveats); can be revisited if the pre-step becomes friction.
