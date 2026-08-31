#!/usr/bin/env bash
#
# Proves the D2 package supply-chain gate end to end: corrupts the cached
# pinned npm tarball by one byte, requires the generator to exit nonzero, and
# restores the cache afterwards. Run via `make d2-renderer-package-check`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/tmp/d2-renderer-package/cache"
GENERATOR="${REPO_ROOT}/scripts/make-d2-renderer-package.sh"
MODE="${1:-}"

if [ "${MODE}" != "--expect-failure" ]; then
    echo "usage: $0 --expect-failure" >&2
    exit 2
fi

TARBALLS=("${CACHE_DIR}"/d2-source-*.tar.gz)
[ -f "${TARBALLS[0]}" ] || {
    echo "error: no cached tarball under ${CACHE_DIR}; run make d2-renderer-package first" >&2
    exit 2
}
TARBALL_PATH="${TARBALLS[0]}"

# A previous SIGKILLed run can leave the corrupted tarball in place with only
# the backup holding good bytes; restore first so this run tampers a good copy.
BACKUP="${TARBALL_PATH}.tamper-backup"
if [ -f "${BACKUP}" ]; then
    mv "${BACKUP}" "${TARBALL_PATH}"
    echo "→ restored a leftover tamper backup before starting"
fi

BACKUP="${TARBALL_PATH}.tamper-backup"
cleanup() {
    if [ -f "${BACKUP}" ]; then
        mv "${BACKUP}" "${TARBALL_PATH}"
    fi
}
trap cleanup EXIT

cp "${TARBALL_PATH}" "${BACKUP}"

# Flip one byte deep inside the file so the size stays identical.
OFFSET=$(( $(wc -c <"${BACKUP}") / 2 ))
printf '\xFF' | dd of="${TARBALL_PATH}" bs=1 seek="${OFFSET}" conv=notrunc status=none

echo "→ tamper leg: corrupted ${TARBALL_PATH} at byte ${OFFSET}"
if "${GENERATOR}" >/dev/null 2>&1; then
    echo "error: generation succeeded despite a corrupted tarball; the supply-chain gate did not fail closed" >&2
    exit 1
fi
echo "→ generator refused the corrupted tarball as required"
