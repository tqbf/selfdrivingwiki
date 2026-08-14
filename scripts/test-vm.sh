#!/bin/bash
# Run the SwiftPM test suite inside a Tart macOS VM.
#
# Containment: swiftpm-testing-helper has been observed sending SIGKILL to
# every user process (PID -1). Running tests in a VM limits the blast radius
# to the guest. See the console log evidence in plans/swiftpm-kill-bug.md.
#
# Prerequisites:
#   brew install cirruslabs/cli/tart
#   tart pull ghcr.io/cirruslabs/macos-tahoe-xcode:latest
#
# Usage:
#   scripts/test-vm.sh              # run full suite
#   scripts/test-vm.sh --filter X   # pass extra swift-test arguments
#   make test-vm                    # via Makefile

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_BASE="${TART_VM_BASE:-ghcr.io/cirruslabs/macos-tahoe-xcode:latest}"
VM_NAME="${TART_VM_NAME:-sdw-test-runner}"
VM_USER="${TART_VM_USER:-admin}"
VM_PASS="${TART_VM_PASS:-admin}"
REMOTE_DIR="/Users/${VM_USER}/selfdrivingwiki"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
SWIFT_TEST_ARGS="${*}"

cleanup() {
    printf '\n→ Stopping VM %s\n' "$VM_NAME"
    tart stop "$VM_NAME" 2>/dev/null || true
    # Do not delete — reuse the clone next time for faster startup.
}
trap cleanup EXIT INT TERM

# --- 1. Create or reuse a clone -------------------------------------------

if tart get "$VM_NAME" >/dev/null 2>&1; then
    printf '→ Reusing existing VM %s\n' "$VM_NAME"
else
    printf '→ Cloning %s → %s\n' "$VM_BASE" "$VM_NAME"
    tart clone "$VM_BASE" "$VM_NAME"
fi

# --- 2. Boot the VM -------------------------------------------------------

printf '→ Starting VM %s\n' "$VM_NAME"
tart run "$VM_NAME" --no-graphics &
VM_PID=$!

# Wait for SSH to become available
printf '→ Waiting for SSH...\n'
VM_IP=""
for attempt in $(seq 1 60); do
    VM_IP="$(tart ip "$VM_NAME" 2>/dev/null || true)"
    if [ -n "$VM_IP" ]; then
        # shellcheck disable=SC2086
        if sshpass -p "$VM_PASS" ssh $SSH_OPTS "${VM_USER}@${VM_IP}" true 2>/dev/null; then
            break
        fi
    fi
    sleep 3
done

if [ -z "$VM_IP" ]; then
    printf '✗ Failed to get VM IP after 60 attempts\n' >&2
    exit 1
fi
printf '  VM IP: %s\n' "$VM_IP"

ssh_cmd() {
    # shellcheck disable=SC2086
    sshpass -p "$VM_PASS" ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "$@"
}

rsync_cmd() {
    # shellcheck disable=SC2086
    sshpass -p "$VM_PASS" rsync -az --delete \
        -e "ssh $SSH_OPTS" \
        "$@"
}

# --- 3. Sync the repo ------------------------------------------------------

printf '→ Syncing repository to VM...\n'
ssh_cmd "mkdir -p ${REMOTE_DIR}"

rsync_cmd \
    --exclude='.build/' \
    --exclude='tmp/' \
    --exclude='.git/objects/' \
    --exclude='RendererPackages/Excalidraw/node_modules/' \
    --filter=':- .gitignore' \
    "${REPO_ROOT}/" "${VM_USER}@${VM_IP}:${REMOTE_DIR}/"

# Sync .git metadata (shallow — just enough for version/prompts)
rsync_cmd \
    --include='.git/' \
    --include='.git/HEAD' \
    --include='.git/config' \
    --include='.git/refs/' \
    --include='.git/refs/**' \
    --exclude='.git/*' \
    "${REPO_ROOT}/" "${VM_USER}@${VM_IP}:${REMOTE_DIR}/"

printf '  ✓ Sync complete\n'

# --- 4. Run tests -----------------------------------------------------------

printf '→ Running tests in VM...\n'
TEST_CMD="cd ${REMOTE_DIR} && swift test --parallel"
if [ -n "$SWIFT_TEST_ARGS" ]; then
    TEST_CMD="cd ${REMOTE_DIR} && swift test ${SWIFT_TEST_ARGS}"
fi

# Run with a timeout — if the test helper goes rogue, the VM contains it
RESULT=0
ssh_cmd "export WIKIFS_APP_TESTS=1; ${TEST_CMD}" || RESULT=$?

# --- 5. Report ---------------------------------------------------------------

if [ "$RESULT" -eq 0 ]; then
    printf '\n✓ Tests passed in VM\n'
else
    printf '\n✗ Tests failed in VM (exit %d)\n' "$RESULT" >&2
fi

# cleanup runs via trap
exit "$RESULT"
