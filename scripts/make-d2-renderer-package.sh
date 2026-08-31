#!/usr/bin/env bash
#
# Generates the D2 read-only renderer package from pinned upstream source and
# hand-authored templates. Nothing under tools/d2/ or RendererPackages/ ships
# D2 bytes in the app bundle: the package is produced into tmp/ and is imported
# manually through Settings → Renderers → Advanced Local Renderer Package
# Import.
#
# The pinned upstream is the d2lang/d2 source at the commit recorded in
# tools/d2/d2-package.lock.json (v0.8.2 or later, the first eval-free WASM
# build: dagre and ELK are pure Go there, so the module needs
# 'wasm-unsafe-eval' but not JS 'unsafe-eval'). The WASM is built locally with
# the recipe in the lock and verified by digest; see tools/d2/DRIVER-NOTES.md.
#
# Requirements: python3, curl, shasum, tar, go (version in the lock), and
# binaryen's wasm-opt (version in the lock).
#
# Usage:
#   scripts/make-d2-renderer-package.sh [--dest <dir>] [--check] [--update-lock]
#
# Modes:
#   (default)      Generate into --dest (default tmp/d2-renderer-package/D2),
#                  verify every digest against tools/d2/d2-package.lock.json,
#                  and validate the result with RendererPackageTool.
#   --check        Re-derive the package into a throwaway directory without
#                  touching the default output, verify every digest against the
#                  lock, and validate it. Exits nonzero on any mismatch.
#   --update-lock  Regenerate the lock's expected asset digests from the fresh
#                  derivation. Use after an intentional template, upstream, or
#                  build-recipe bump; the lock diff is the reviewable
#                  provenance change.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/tools/d2"
LOCK_PATH="${TEMPLATE_DIR}/d2-package.lock.json"
DEFAULT_DEST="${REPO_ROOT}/tmp/d2-renderer-package/D2"
CACHE_PARENT="${REPO_ROOT}/tmp/d2-renderer-package/cache"

MODE="generate"
DEST="${DEFAULT_DEST}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dest)
            [ "$#" -ge 2 ] || { echo "error: --dest requires a directory" >&2; exit 2; }
            DEST="$2"
            shift 2
            ;;
        --check)
            MODE="check"
            shift
            ;;
        --update-lock)
            MODE="update-lock"
            shift
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

for tool in python3 curl shasum tar go wasm-opt; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "error: required tool not found: ${tool}" >&2
        echo "  go: https://go.dev/dl/  wasm-opt: brew install binaryen" >&2
        exit 1
    }
done

if [ "${MODE}" = "check" ]; then
    CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/d2-renderer-package-check.XXXXXX")"
    DEST="${CHECK_ROOT}/D2"
fi

cleanup() {
    if [ -n "${CHECK_ROOT:-}" ] && [ -d "${CHECK_ROOT}" ]; then
        rm -rf "${CHECK_ROOT}"
    fi
    if [ -n "${STAGING:-}" ] && [ -d "${STAGING}" ]; then
        rm -rf "${STAGING}"
    fi
}
trap cleanup EXIT

mkdir -p "${DEST}" "${CACHE_PARENT}"

# --- Read pinned values from the lock ---------------------------------------

lock_field() {
    python3 - "${LOCK_PATH}" "$@" <<'PY'
import json, sys

lock = json.load(open(sys.argv[1]))
value = lock
for key in sys.argv[2:]:
    value = value[key]
if isinstance(value, str):
    sys.stdout.write(value)
else:
    sys.stdout.write(json.dumps(value))
PY
}

SOURCE_TARBALL_URL="$(lock_field upstream sourceTarballURL)"
SOURCE_TARBALL_SHA="$(lock_field upstream sourceTarballSHA256)"
UPSTREAM_NAME="$(lock_field upstream name)"
UPSTREAM_VERSION="$(lock_field upstream version)"
UPSTREAM_COMMIT="$(lock_field upstream commit)"
UPSTREAM_SOURCE_URL="$(lock_field upstream sourceURL)"
GENERATED_AT="$(lock_field generatedAt)"
PACKAGE_ID="$(lock_field package packageID)"
PACKAGE_VERSION="$(lock_field package version)"
REGISTRATION_ID="$(lock_field package registrationID)"
WASM_EXEC_RELATIVE="$(lock_field wasmExec pathInSource)"
WASM_EXEC_SHA="$(lock_field wasmExec sha256)"
GO_VERSION="$(lock_field build goVersion)"
WASM_OPT_VERSION="$(lock_field build wasmOptVersion)"
LDFLAGS="$(lock_field build ldflags)"
SOURCE_PACKAGE="$(lock_field build sourcePackage)"
OPTIMIZE_FLAGS="$(lock_field build optimizeFlags | python3 -c 'import json,sys; sys.stdout.write(" ".join(json.load(sys.stdin)))')"

echo "→ pinned upstream: ${UPSTREAM_NAME}@v${UPSTREAM_VERSION} (${UPSTREAM_COMMIT})"

# --- Toolchain versions must match the lock, or the build is not the build ---

ACTUAL_GO_VERSION="$(go version | awk '{print $3}')"
if [ "${ACTUAL_GO_VERSION}" != "${GO_VERSION}" ]; then
    echo "error: go toolchain mismatch" >&2
    echo "  lock expects: ${GO_VERSION}" >&2
    echo "  found:        ${ACTUAL_GO_VERSION}" >&2
    exit 1
fi
ACTUAL_WASM_OPT_VERSION="$(wasm-opt --version)"
case "${ACTUAL_WASM_OPT_VERSION}" in
    *"${WASM_OPT_VERSION}"*) ;;
    *)
        echo "error: wasm-opt version mismatch" >&2
        echo "  lock expects: ${WASM_OPT_VERSION}" >&2
        echo "  found:        ${ACTUAL_WASM_OPT_VERSION}" >&2
        exit 1
        ;;
esac
echo "→ toolchains match the lock (${ACTUAL_GO_VERSION}, wasm-opt ${ACTUAL_WASM_OPT_VERSION})"

# --- Fetch and verify the pinned source tarball (the supply-chain gate) ------

TARBALL_PATH="${CACHE_PARENT}/d2-source-${UPSTREAM_VERSION}.tar.gz"

fetch_tarball() {
    echo "→ downloading ${SOURCE_TARBALL_URL}"
    curl -fsSL -o "${TARBALL_PATH}.partial" "${SOURCE_TARBALL_URL}"
    mv "${TARBALL_PATH}.partial" "${TARBALL_PATH}"
}

if [ ! -f "${TARBALL_PATH}" ]; then
    fetch_tarball
fi

ACTUAL_TARBALL_SHA="$(shasum -a 256 "${TARBALL_PATH}" | awk '{print $1}')"
if [ "${ACTUAL_TARBALL_SHA}" != "${SOURCE_TARBALL_SHA}" ]; then
    echo "error: source tarball SHA-256 mismatch (supply-chain gate)" >&2
    echo "  expected: ${SOURCE_TARBALL_SHA}" >&2
    echo "  actual:   ${ACTUAL_TARBALL_SHA}" >&2
    echo "Delete ${TARBALL_PATH} and rerun to refetch." >&2
    exit 1
fi
echo "→ source tarball digest verified: ${SOURCE_TARBALL_SHA}"

# --- Build the WASM with the locked recipe ------------------------------------

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/d2-renderer-package-stage.XXXXXX")"

SOURCE_ROOT="${STAGING}/d2src"
mkdir -p "${SOURCE_ROOT}"
tar -xzf "${TARBALL_PATH}" -C "${SOURCE_ROOT}" --strip-components 1

WASM_EXEC_PATH="${SOURCE_ROOT}/${WASM_EXEC_RELATIVE}"
[ -f "${WASM_EXEC_PATH}" ] || {
    echo "error: source tree is missing ${WASM_EXEC_RELATIVE}" >&2
    exit 1
}
ACTUAL_WASM_EXEC_SHA="$(shasum -a 256 "${WASM_EXEC_PATH}" | awk '{print $1}')"
if [ "${ACTUAL_WASM_EXEC_SHA}" != "${WASM_EXEC_SHA}" ]; then
    echo "error: wasm_exec.js SHA-256 mismatch" >&2
    echo "  expected: ${WASM_EXEC_SHA}" >&2
    echo "  actual:   ${ACTUAL_WASM_EXEC_SHA}" >&2
    exit 1
fi

echo "→ building ${SOURCE_PACKAGE} with the locked recipe"
(
    cd "${SOURCE_ROOT}"
    GOOS=js GOARCH=wasm go build -ldflags="${LDFLAGS}" -trimpath -buildvcs=false \
        -o "${STAGING}/d2.wasm" "${SOURCE_PACKAGE}"
)
# shellcheck disable=SC2086 — OPTIMIZE_FLAGS is a flag list by design; the
# flags carry no arguments and are pinned in the lock.
wasm-opt ${OPTIMIZE_FLAGS} "${STAGING}/d2.wasm" -o "${STAGING}/d2.wasm.opt"
mv "${STAGING}/d2.wasm.opt" "${STAGING}/d2.wasm"
echo "→ WASM built and optimized (digest is verified against the lock below)"

# --- Assemble the package ----------------------------------------------------

# Start from a clean destination: a stale file from a previous run must never
# enter the manifest. The destination is guarded because rm -rf must never
# follow a mistaken --dest outside this repository's tmp/ tree (the --check
# throwaway root is exempt).
if [ "${MODE}" = "check" ]; then
    case "${DEST}" in
        "${CHECK_ROOT}"/*) ;;
        *)
            echo "error: --check destination must live under the check root" >&2
            exit 2
            ;;
    esac
else
    case "${DEST}" in
        "${REPO_ROOT}/tmp/"*|"${REPO_ROOT}/tmp") ;;
        *)
            echo "error: --dest must live under ${REPO_ROOT}/tmp/ (got ${DEST})" >&2
            exit 2
            ;;
    esac
fi
rm -rf "${DEST}"
mkdir -p "${DEST}"

cp "${TEMPLATE_DIR}/index.html" "${TEMPLATE_DIR}/d2-viewer.js" "${DEST}/"
cp "${TEMPLATE_DIR}/MPL-2.0.txt" "${DEST}/LICENSE.txt"
cp "${WASM_EXEC_PATH}" "${DEST}/wasm_exec.js"
cp "${STAGING}/d2.wasm" "${DEST}/d2.wasm"

# Upstream ships the authoritative third-party notices for the d2js artifact;
# copy them verbatim behind a short assembly note.
cat > "${DEST}/THIRD_PARTY_NOTICES.txt" <<'NOTES'
D2 renderer package third-party notices
=======================================

The notices below are upstream's own third-party notices for the pinned d2js
WASM artifact, copied verbatim from the pinned source tree
(d2js/js/THIRD_PARTY_NOTICES.txt). The package also ships Go's wasm_exec.js
runtime support file (BSD-3-Clause, The Go Authors); the canonical D2 license
text (MPL-2.0) ships as LICENSE.txt.

NOTES
cat "${SOURCE_ROOT}/d2js/js/THIRD_PARTY_NOTICES.txt" >> "${DEST}/THIRD_PARTY_NOTICES.txt"

render_provenance() {
    python3 - "${TEMPLATE_DIR}/PROVENANCE.template.md" "${DEST}/PROVENANCE.md" \
        "${LOCK_PATH}" \
        "${PACKAGE_ID}" "${PACKAGE_VERSION}" "${GENERATED_AT}" \
        "${UPSTREAM_SOURCE_URL}" "${UPSTREAM_NAME}" "${UPSTREAM_VERSION}" \
        "${UPSTREAM_COMMIT}" "${SOURCE_TARBALL_URL}" "${SOURCE_TARBALL_SHA}" \
        "${WASM_EXEC_SHA}" "${STAGING}/d2.wasm" <<'PY'
import hashlib, json, sys

source, dest, lock_path = sys.argv[1], sys.argv[2], sys.argv[3]
values = sys.argv[4:]
lock = json.load(open(lock_path))
build = lock["build"]
recipe = (
    "```text\n"
    + "GOOS=js GOARCH=wasm go build -ldflags='" + build["ldflags"]
        + "' -trimpath -buildvcs=false -o d2.wasm " + build["sourcePackage"] + "\n"
    + "wasm-opt " + " ".join(build["optimizeFlags"]) + " -o d2.wasm d2.wasm\n"
    + "```"
)
text = open(source).read()
placeholders = [
    "PACKAGEID", "PACKAGEVERSION", "GENERATEDAT", "SOURCEURL",
    "UPSTREAMNAME", "UPSTREAMVERSION", "UPSTREAMCOMMIT", "TARBALLURL",
    "TARBALLSHA256", "WASMEXECSHA256", "D2WASMSHA256",
]
wasm_path = values.pop()
digest = hashlib.sha256(open(wasm_path, "rb").read()).hexdigest()
values.append(digest)
for name, value in zip(placeholders, values):
    text = text.replace("@@" + name + "@@", value)
# The build recipe renders from the lock so a recipe edit can never leave
# PROVENANCE.md describing stale flags.
text = text.replace("@@BUILDRECIPE@@", recipe)
open(dest, "w").write(text)
PY
}

render_provenance
echo "→ provenance rendered (generatedAt pinned to ${GENERATED_AT})"

# --- Digests, manifest, and lock verification --------------------------------

python3 - "${LOCK_PATH}" "${DEST}" "${MODE}" <<'PY'
import hashlib, json, os, sys

lock_path, dest, mode = sys.argv[1], sys.argv[2], sys.argv[3]
lock = json.load(open(lock_path))

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

package_id = lock["package"]["packageID"]
version = lock["package"]["version"]
registration_id = lock["package"]["registrationID"]

entries = []
for root, _, files in os.walk(dest):
    for name in files:
        full = os.path.join(root, name)
        relative = os.path.relpath(full, dest)
        entries.append((relative.replace(os.sep, "/"), sha256(full)))
entries.sort()

expected = lock.get("expectedAssets", {})
actual = dict(entries)

if mode == "update-lock":
    lock["expectedAssets"] = actual
    with open(lock_path, "w") as handle:
        json.dump(lock, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("→ lock updated with {} expected asset digests".format(len(actual)))
else:
    mismatched = sorted(
        path for path, digest in actual.items()
        if expected.get(path) != digest
    )
    if mismatched:
        print("error: derived assets do not match the lock:", file=sys.stderr)
        for path in mismatched:
            print("  {}".format(path), file=sys.stderr)
        print("Run scripts/make-d2-renderer-package.sh --update-lock if the "
              "change is intentional.", file=sys.stderr)
        sys.exit(1)
    missing = sorted(set(expected) - set(actual))
    if missing:
        print("error: lock expects assets the package no longer has:", file=sys.stderr)
        for path in missing:
            print("  {}".format(path), file=sys.stderr)
        sys.exit(1)

asset_records = [
    {"path": path, "digest": digest}
    for path, digest in entries
]
manifest = {
    "revision": 2,
    "packageID": package_id,
    "version": version,
    "descriptors": [
        {
            "reference": {
                "packageID": package_id,
                "version": version,
                "registrationID": registration_id,
            },
            "displayName": lock["package"]["displayName"],
            "implementation": {"webPackage": {"_0": {"path": "index.html"}}},
            "matchers": [{"extensionFallback": {"_0": "d2"}}],
            "presentations": ["web"],
            "supportedEmbeddingRoles": lock["package"]["supportedEmbeddingRoles"],
            "approvedAssets": asset_records,
            "capabilities": lock["package"]["capabilities"],
            "sizeLimits": lock["package"]["sizeLimits"],
            "linkPolicy": lock["package"]["linkPolicy"],
            "accessibility": lock["package"]["accessibility"],
            "compatibility": lock["package"]["compatibility"],
            "priority": lock["package"]["priority"],
        }
    ],
    "assets": asset_records,
}

# Fence claims are package data: the lock declares them, the manifest carries
# them, and no host Swift learns the alias. Omit the key when a lock has no
# claims so canonical bytes stay identical to claim-less packages.
fence_claims = lock["package"].get("fenceClaims") or []
if fence_claims:
    manifest["descriptors"][0]["fenceClaims"] = fence_claims
with open(os.path.join(dest, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("→ manifest written ({} assets, revision 2)".format(len(asset_records)))
PY

if [ "${MODE}" = "update-lock" ]; then
    echo "→ package assembled at ${DEST}"
    exit 0
fi

# --- Validate -----------------------------------------------------------------

echo "→ validating with RendererPackageTool"
(
    cd "${REPO_ROOT}"
    swift run RendererPackageTool validate "${DEST}"
)

if [ "${MODE}" = "check" ]; then
    echo "✓ check passed: full derivation matches the lock and validates"
else
    echo "✓ package generated at ${DEST}"
    echo ""
    echo "Import it through Settings → Renderers → Advanced Local Renderer"
    echo "Package Import. The app copies and validates the folder; the tmp/"
    echo "output is not used by the app after import."
fi
