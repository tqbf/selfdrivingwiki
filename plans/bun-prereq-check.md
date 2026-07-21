# Plan: Move bun prerequisite check up front (#762)

## Problem
`build.sh` checks for `bun` at line 132 — *after* `swift build -c ${CONFIG}`
(line 92) has already compiled the entire project. A developer without bun
installed waits through the full Swift compile before discovering the missing
prerequisite.

## Root cause
The bun check lives in the bundling section of `build.sh`, which runs
post-compile. The Makefile's `build` target calls `./build.sh` without any
bun validation of its own.

## Fix (two parts)

### 1. `build.sh` — up-front gate (before `swift build`)
Add a bun-existence check near the top of `build.sh`, after the early
validation block (config parsing, identifier setup) and **before** the
`swift build -c "${CONFIG}"` call at line 92.

Resolution chain (same as the bundling logic, extended with a PATH fallback):
1. `${BUN_INSTALL}/bin/bun`
2. `$HOME/.bun/bin/bun`
3. `command -v bun` (PATH lookup)

If none found, print the existing install hint and `exit 1`:

```
✗ FATAL: bun not found
  Install it:  curl -fsSL https://bun.sh/install | bash
  Or set BUN_INSTALL to point at your bun binary's directory.
```

The existing bundling logic at L132 stays — it copies the *resolved* binary
into `helpers/`. The up-front gate just fails fast if there's nothing to
copy.

### 2. `Makefile` — gate `build` (not `check`/`test`)

**Constraint:** `deps` is a shared prerequisite of `build`, `check`, `test`,
`test-fast`, and `check-release`. Adding a bun check to `deps` would break
`make check` / `make test`, which do NOT bundle and therefore do NOT need bun.

**Approach:** Add a dedicated `bun-check` target and make it a prerequisite
of `build` and `release` only:

```make
bun-check:
	@BUN_SRC="${BUN_INSTALL:-$$HOME/.bun}/bin/bun"; \
	if [ -x "$$BUN_SRC" ]; then ...; \
	elif command -v bun >/dev/null 2>&1; then ...; \
	else echo "✗ FATAL: bun not found" >&2; ...; exit 1; fi
```

Update:
- `build: deps bun-check $(APP_ICON) $(GENERATED_PROMPTS) version`
- `release: deps bun-check $(APP_ICON) $(GENERATED_PROMPTS) version`

Leave `check`, `test`, `test-fast`, `check-release` unchanged.

## Guardrails
- ✓ Only gate `build` / `release` — not `check` / `test` / `test-fast`.
- ✓ Reuse the existing error message (install command + BUN_INSTALL hint).
- ✓ No `print` in Swift (shell/Makefile only — `echo` is fine).
- ✓ Verify: with bun present, `make build` succeeds. Without bun, fails
  immediately (before `swift build`).

## Verification
1. `make build` — should succeed (bun present on this machine).
2. `make test` — should succeed (unaffected by bun gate).
3. Push branch, open PR with `Closes #762`. Do NOT merge to main.
