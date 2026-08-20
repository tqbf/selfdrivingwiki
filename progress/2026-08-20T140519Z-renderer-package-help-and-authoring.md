# Renderer package help and authoring

Date: 2026-08-20
Branch: `feature/renderer-package-help`

## Implemented

- Added a labeled renderer-package Help control to Settings → Renderers.
- Added a bounded native popover with system text styles and accessible labels.
- Kept the existing advanced local import disclosure and directory picker unchanged.
- Added the missing user-guide index and a renderer-package user guide.
- Expanded the renderer-package maintainer skill with a complete authoring workflow.
- Added a semantic two-file minimal package template with an exact SHA-256 digest.
- Added `RendererPackageToolCore` and the thin `RendererPackageTool` executable.
- Confined validation to invocation-owned `packages` and `staging` roots.
- Removed the complete invocation root after success and failure.
- Added typed JSON output and actionable stderr diagnostics.
- Added Core, subprocess, documentation, template, and opt-in Settings tests.

## Automated evidence

The following focused command passed with 11 tests:

```text
swift test --filter 'RendererPackageTool|RendererPackageDocumentationTests'
```

The following opt-in Settings command passed with 9 tests:

```text
WIKIFS_APP_TESTS=1 swift test --filter 'RendererSettingsHelpHostedTests|RendererSettingsHelpContentTests|RendererSettingsManagementViewTests|RendererSettingsPackagePickerTests'
```

The final required gates passed on the stable final tree:

```text
make build
make test
swift build
swift test
```

Bare `swift test` reported 3,479 passing tests in 337 suites.

`git diff --check` passed.

Both `.polytoken/skills` and `.claude/skills` remain symlinks to `../docs/skills`.

The repository instruction names `scripts/validate-skills`, but that command is absent. It was not reported as passed. The documentation tests validate the skill front matter, links, template paths, exact digest, and production validator acceptance.

## Review evidence

An OpenAI-family model authored the implementation. Two configured reviewers also used the OpenAI family. Their reviews were independent in context but did not satisfy the model-family diversity requirement. No eligible alternate model family was available through the configured subagents.

The plan review found two high issues:

1. The machine-store sentinel did not observe validator-root construction.
2. The hosted Settings test did not exercise the presentation binding.

Both issues were fixed. The tool now injects and tests the validator factory with exact invocation-owned roots. The hosted test mounts the real control and verifies presentation and dismissal through the binding seam.

The reviewers also found subprocess pipe and timeout risks. The tests now capture stdout and stderr in temporary files. They use a termination handler, a timeout race, and a bounded post-terminate wait. The subprocess suite covers success and nonzero failure.

No unresolved critical or high review finding remains.

## Manual checks

This text-only harness could not inspect the visible app or VoiceOver speech. The following checks remain for an operator:

- Open Settings → Renderers.
- Reach the Help button with the keyboard.
- Open and dismiss the popover with standard controls.
- Inspect the copy and folder diagram in light and dark appearances.
- Confirm that VoiceOver announces the Help trigger and popover heading.
- Confirm that Import still opens a directory-only panel.

Automated hosted tests cover real macOS layout, system text styles, accessibility labels, presentation state, and the existing directory-only picker contract.
