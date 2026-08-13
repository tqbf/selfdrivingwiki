#!/usr/bin/env bash
# Run the optional, nonblocking Linux source-portability diagnostic in an OCI
# runtime. Linux is not a supported product platform. This script never uses the
# host Swift toolchain for code generation, building, or testing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/scripts/lib/linux-swift-test-config.sh"
# swift:6.3.3-noble, an Ubuntu 24.04 multi-architecture manifest list.
DEFAULT_IMAGE='docker.io/library/swift@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea'
IMAGE="${LINUX_TEST_IMAGE:-$DEFAULT_IMAGE}"
PLATFORM='linux/amd64'
REQUESTED_RUNTIME="${LINUX_TEST_RUNTIME:-auto}"
TEST_FILTER="${LINUX_TEST_FILTER:-}"

source "$CONFIG_FILE"

if [[ -z "$TEST_FILTER" ]]; then
    TEST_FILTER="$LINUX_SWIFT_TEST_FILTER"
fi

if [[ "$TEST_FILTER" != WikiFSCoreTests* ]]; then
    echo "failed to select portable tests: LINUX_TEST_FILTER must start with WikiFSCoreTests" >&2
    exit 2
fi

if [[ "$IMAGE" != *@sha256:* ]]; then
    echo "failed to select Linux image: LINUX_TEST_IMAGE must include an immutable sha256 digest" >&2
    exit 2
fi

case "$REQUESTED_RUNTIME" in
    auto)
        if command -v container >/dev/null 2>&1; then
            RUNTIME='container'
        elif command -v docker >/dev/null 2>&1; then
            RUNTIME='docker'
        else
            echo "failed to select Linux runtime: install Apple container or Docker; this optional diagnostic has no CI equivalent" >&2
            exit 2
        fi
        ;;
    container|docker)
        if ! command -v "$REQUESTED_RUNTIME" >/dev/null 2>&1; then
            echo "failed to select Linux runtime: requested '$REQUESTED_RUNTIME' is not installed" >&2
            exit 2
        fi
        RUNTIME="$REQUESTED_RUNTIME"
        ;;
    *)
        echo "failed to select Linux runtime: use auto, container, or docker" >&2
        exit 2
        ;;
esac

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
EVIDENCE_DIR="$REPO_ROOT/tmp/linux-test/$RUN_ID"
RUNTIME_LOG="$EVIDENCE_DIR/runtime.log"
CONTAINER_LOG="$EVIDENCE_DIR/container.log"
TOOLCHAIN_LOG="$EVIDENCE_DIR/toolchain.log"
EVIDENCE_FILE="$EVIDENCE_DIR/evidence.txt"
mkdir -p "$EVIDENCE_DIR"

TEST_COMMAND="swift test -v --parallel --num-workers $LINUX_SWIFT_TEST_NUM_WORKERS --filter $TEST_FILTER --skip $LINUX_SWIFT_TEST_SKIP"

{
    printf 'runtime=%s\n' "$RUNTIME"
    printf 'image=%s\n' "$IMAGE"
    printf 'platform=%s\n' "$PLATFORM"
    printf 'host_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD)"
    printf 'package_resolved_sha256=%s\n' "$(shasum -a 256 "$REPO_ROOT/Package.resolved" | awk '{print $1}')"
    printf 'test_filter=%s\n' "$TEST_FILTER"
    printf 'skip_list=%s\n' "$LINUX_SWIFT_TEST_SKIP"
    printf 'workers=%s\n' "$LINUX_SWIFT_TEST_NUM_WORKERS"
    printf 'test_command=%s\n' "$TEST_COMMAND"
    printf 'runtime_log=%s\n' "$RUNTIME_LOG"
    printf 'toolchain_log=%s\n' "$TOOLCHAIN_LOG"
    printf 'container_log=%s\n' "$CONTAINER_LOG"
} >"$EVIDENCE_FILE"

if [[ "$RUNTIME" == docker ]]; then
    if ! docker info >"$RUNTIME_LOG" 2>&1; then
        echo "failed to contact the Docker daemon. See $RUNTIME_LOG" >&2
        exit 1
    fi
else
    if ! container --version >"$RUNTIME_LOG" 2>&1; then
        echo "failed to inspect Apple container. See $RUNTIME_LOG" >&2
        exit 1
    fi
fi
RUNTIME_VERSION="$(tr '\n' ' ' <"$RUNTIME_LOG" | sed 's/[[:space:]]*$//')"
printf 'runtime_version=%s\n' "$RUNTIME_VERSION" >>"$EVIDENCE_FILE"

if [[ "$RUNTIME" == docker ]]; then
    if ! docker pull --platform "$PLATFORM" "$IMAGE" >>"$RUNTIME_LOG" 2>&1; then
        echo "failed to pull the Linux image. See $RUNTIME_LOG" >&2
        exit 1
    fi
    if ! docker run --rm --platform "$PLATFORM" "$IMAGE" swift --version >"$TOOLCHAIN_LOG" 2>&1; then
        echo "failed to inspect the Linux Swift toolchain. See $TOOLCHAIN_LOG" >&2
        exit 1
    fi
else
    if ! container image pull --platform "$PLATFORM" "$IMAGE" >>"$RUNTIME_LOG" 2>&1; then
        echo "failed to pull the Linux image. See $RUNTIME_LOG" >&2
        exit 1
    fi
    if ! container run --rm --platform "$PLATFORM" --rosetta "$IMAGE" swift --version >"$TOOLCHAIN_LOG" 2>&1; then
        echo "failed to inspect the Linux Swift toolchain. See $TOOLCHAIN_LOG" >&2
        exit 1
    fi
fi
TOOLCHAIN_VERSION="$(tr '\n' ' ' <"$TOOLCHAIN_LOG" | sed 's/[[:space:]]*$//')"
printf 'swift_version=%s\n' "$TOOLCHAIN_VERSION" >>"$EVIDENCE_FILE"

echo "==> Linux runtime: $RUNTIME"
echo "==> Image: $IMAGE"
echo "==> Platform: $PLATFORM"
echo "==> Evidence: $EVIDENCE_FILE"
echo "==> Test log: $CONTAINER_LOG"

CONTAINER_COMMAND='set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -q install -y --no-install-recommends libsqlite3-dev make
mkdir -p /work
cp -a /workspace/. /work/
cd /work
rm -rf .build
make version prompts keychain
printf "==> Container Swift: "; swift --version
swift build --target WikiFSCoreTests
swift test -v --parallel --num-workers "$LINUX_SWIFT_TEST_NUM_WORKERS" --filter "$LINUX_TEST_FILTER" --skip "$LINUX_SWIFT_TEST_SKIP"'

set +e
if [[ "$RUNTIME" == docker ]]; then
    docker run --rm \
        --platform "$PLATFORM" \
        --volume "$REPO_ROOT:/workspace:ro" \
        --workdir /workspace \
        --env LINUX_SWIFT_TEST_NUM_WORKERS="$LINUX_SWIFT_TEST_NUM_WORKERS" \
        --env LINUX_TEST_FILTER="$TEST_FILTER" \
        --env LINUX_SWIFT_TEST_SKIP="$LINUX_SWIFT_TEST_SKIP" \
        "$IMAGE" /bin/bash -lc "$CONTAINER_COMMAND" 2>&1 | tee "$CONTAINER_LOG"
else
    container run --rm \
        --platform "$PLATFORM" \
        --rosetta \
        --volume "$REPO_ROOT:/workspace:ro" \
        --workdir /workspace \
        --env LINUX_SWIFT_TEST_NUM_WORKERS="$LINUX_SWIFT_TEST_NUM_WORKERS" \
        --env LINUX_TEST_FILTER="$TEST_FILTER" \
        --env LINUX_SWIFT_TEST_SKIP="$LINUX_SWIFT_TEST_SKIP" \
        "$IMAGE" /bin/bash -lc "$CONTAINER_COMMAND" 2>&1 | tee "$CONTAINER_LOG"
fi
TEST_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$TEST_STATUS" -ne 0 ]]; then
    echo "failed to run Linux tests (exit $TEST_STATUS). Retained diagnostics: $CONTAINER_LOG" >&2
    exit "$TEST_STATUS"
fi

echo "✓ Linux portable tests pass. Evidence: $EVIDENCE_FILE"
