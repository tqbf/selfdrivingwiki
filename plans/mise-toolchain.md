# Optional development tools

Issue #1135 evaluated mise as a repository tool manager for external runtimes. The core app does not require mise, Bun, or uv; they support optional integrations only.

## Configuration

`mise.toml` pins:

- `bun` 1.4.0, used by Defuddle and ACP provider commands.
- `uv` 0.9.0, used by the PEP 723 PDF and transcript scripts.

From a fresh checkout, install mise and the optional tools only when you need an integration:

```sh
# Install mise: https://mise.jdx.dev/getting-started.html
mise install
mise exec -- bun --version
mise exec -- uv --version
```

`make build` and `make test` do not install or require these tools. If an optional runtime is absent, the affected feature reports that it is unavailable and uses its fallback.

## Build and runtime behavior

The app does not package `bun` or `uv` in `Contents/Helpers`. `build.sh` only packages app-owned helpers and scripts. Runtime subprocesses resolve the tools from PATH, with the mise shims directory included for Finder-launched processes. A missing tool produces a clear `mise install` message and the affected feature falls back where supported.

CI runs the core Swift and skill checks without requiring these optional runtimes. Integration-specific jobs may use `mise.toml` when they exercise the corresponding scripts.

## Version updates

Update `mise.toml`, run `mise lock`, and commit both files when changing the optional integration toolchain. Verify the affected script directly; core builds remain independent of these tools.
