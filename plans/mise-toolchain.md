# Mise-managed development tools

Issue #1135 makes `mise` the repository tool manager for the external runtimes used by the development tools.

## Configuration

`mise.toml` pins:

- `bun` 1.4.0, used by Defuddle and ACP provider commands.
- `uv` 0.9.0, used by the PEP 723 PDF and transcript scripts.

From a fresh checkout:

```sh
# Install mise: https://mise.jdx.dev/getting-started.html
mise install
mise exec -- bun --version
mise exec -- uv --version
```

Use `mise install` from the repository root before `make build` or `make test`.

## Build and runtime behavior

The app does not package `bun` or `uv` in `Contents/Helpers`. `build.sh` only packages app-owned helpers and scripts. Runtime subprocesses resolve the tools from PATH, with the mise shims directory included for Finder-launched processes. A missing tool produces a clear `mise install` message and the affected feature falls back where supported.

CI uses `jdx/mise-action` and the same `mise.toml`, so local development and CI use the same tool selectors.

## Version updates

Update `mise.toml`, run `mise lock`, and commit both files. Verify the Defuddle bundle and PDF/transcript scripts with `make build` and the relevant tests.
