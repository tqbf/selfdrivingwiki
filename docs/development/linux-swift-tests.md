# Run the optional Linux Swift diagnostic

Self Driving Wiki supports macOS only. Use this procedure only as a best-effort
Linux source-portability diagnostic. It is not a pull-request or release gate,
and its failure must not block macOS readiness. It tests the portable
`WikiFSCoreTests` target only and reproduces the former `linux-swift` job contract.

## Requirements

Install one OCI runtime. The runner selects Apple `container` first when it is
available. Otherwise, it selects Docker.

The default image is `swift:6.3.3-noble` with an immutable manifest digest. It
uses the `linux/amd64` platform, Swift 6.3.3, and Ubuntu 24.04. GitHub-hosted
Ubuntu is x86_64 and uses Swift 6.3. The local runner fixes the architecture,
patch release, and base image for repeatable results.

Do not install a Linux runtime only for this command. macOS command-line SwiftPM
and hosted macOS checks remain the required validation path. This diagnostic is
optional and nonblocking. The retained EINTR failure record is
[`progress/2026-08-13T000000Z-linux-swift-eintr-failure-record.md`](../../progress/2026-08-13T000000Z-linux-swift-eintr-failure-record.md).

## Run the suite

From the repository root, run this command:

```sh
make test-linux
```

The command starts a Linux container. It installs `libsqlite3-dev` and `make`,
creates a container-local copy of the checkout, generates required files, builds
`WikiFSCoreTests`, and runs the former CI test command as an optional diagnostic.

The diagnostic command uses the shared configuration in
`scripts/lib/linux-swift-test-config.sh`:

```sh
swift test --parallel --num-workers 1 --filter WikiFSCoreTests --skip <former Linux diagnostic skip list>
```

The `WikiFSCoreTests` filter is required. An unfiltered SwiftPM test command
can build MLX targets that require CUDA headers on Linux.

To test one portable suite, give its full SwiftPM filter:

```sh
make test-linux-focus TEST_FILTER=WikiFSCoreTests.RendererStoreTests
```

The focused filter must start with `WikiFSCoreTests`. The runner still applies
the former CI skip list and uses one worker.

## Select a runtime or image

The automatic selection is visible in the command output and evidence. To
select a runtime explicitly, set `LINUX_TEST_RUNTIME`:

```sh
LINUX_TEST_RUNTIME=container make test-linux
LINUX_TEST_RUNTIME=docker make test-linux
```

Valid values are `auto`, `container`, and `docker`. An explicit request fails
when that runtime is not installed. The runner does not switch runtimes after
an explicit request.

To test a replacement image, set `LINUX_TEST_IMAGE`. The value must include a
SHA-256 digest. This prevents a moving tag from changing the test environment.

```sh
LINUX_TEST_IMAGE='docker.io/library/swift@sha256:<digest>' make test-linux
```

## Evidence and failures

Each run creates `tmp/linux-test/<UTC timestamp>-<commit>/`. The directory
contains these files:

| File | Contents |
| --- | --- |
| `evidence.txt` | Runtime, image digest, platform, Swift version, commit, `Package.resolved` hash, filter, skip list, worker count, and command. |
| `runtime.log` | Runtime availability and image-pull diagnostics. |
| `toolchain.log` | The Swift version from the Linux image. |
| `container.log` | Image pull output, package installation output, build output, and verbose Swift Testing diagnostics. |

The runner keeps this directory for both success and failure. Send
`runtime.log`, `container.log`, and `evidence.txt` with a portability failure
report.

## Cache and cleanup

The runtime caches the pinned image. The runner removes its container after
each run. It does not reuse the container workspace, package cache, or build
directory. This keeps each test isolated from macOS `.build` artifacts.

Remove old evidence when you no longer need it:

```sh
rm -rf tmp/linux-test
```

To remove the pinned image, use your selected runtime:

```sh
container image delete docker.io/library/swift@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea
docker image rm docker.io/library/swift@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea
```

## Common runtime errors

If Docker reports that it cannot connect to its socket, start Docker Desktop
or the Docker daemon. Run the command again after the daemon is ready.

If Apple `container` reports a machine, image, or virtualization error, run
`container --version` and check the Apple Container requirements. Use Docker
with `LINUX_TEST_RUNTIME=docker` when Docker is available.

The runner uses the `linux/amd64` image to match GitHub-hosted Ubuntu. Apple
Container uses Rosetta for this image on Apple Silicon.

Do not restart Paseo, the app daemon, or unrelated services. This runner uses
only a temporary Linux container and a read-only checkout mount.
