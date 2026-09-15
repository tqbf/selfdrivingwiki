#!/bin/bash
#
# Sync + gate the vendored Claude ACP adapter (#1257 Level 2).
#
#   scripts/sync-acp-adapter.sh            regenerate the bundle + records
#   scripts/sync-acp-adapter.sh --check    fail when anything is stale or disagreeing
#
# The adapter ships as a committed single-file bundle
# (Resources/claude-acp-adapter.bundle.js) built from the npm package pinned
# in tools/claude-acp-adapter/, launched by the app as
# `<resolved bun> run <Helpers>/claude-acp-adapter.js`. The reviewed bytes
# must never drift from the reviewed provenance, so every version-bearing
# record is GENERATED from ONE source of truth: the variables below.
#
#   ADAPTER_VERSION → tools/claude-acp-adapter/package.json  (dependency pin)
#                     Sources/WikiFSEngine/VendoredAdapterPin.swift (compile-time pin)
#                     tools/claude-acp-adapter/adapter.lock.json   (provenance record)
#
# To bump the adapter: change ADAPTER_VERSION, fill ADAPTER_DIST_INTEGRITY /
# ADAPTER_DIST_SHASUM from `npm view <pkg>@<version> dist.integrity
# dist.shasum`, run `make acp-adapter-sync`, review the generated diff (lock
# JSON, package.json, Swift pin, bundle), then run the gates. Never
# hand-edit the generated records — a hand edit makes `--check` fail by
# design.
#
# How the gate works
# ------------------
# `--check` uses no network and no bun. It re-derives every generated value
# from the variables below and compares them against the tree: the lock
# record's version/tarball/dist metadata, the sha256 of package.json, the
# committed bun.lock, and the committed bundle, plus the package.json
# dependency pin and the Swift pin constants. A hand-edited bundle, a
# changed variable without a re-sync, or two records that disagree each
# fail the gate.
#
# `sync` needs bun + network (npm registry metadata + bun install). When bun
# is absent and the pinned version is UNCHANGED, the committed bundle and
# lockfile are kept and the step is reported — the same degradation the
# Defuddle step in scripts/sync-extractor-packages.sh uses. A version bump
# without bun is a hard error: the bundle cannot be rebuilt and the dist
# metadata for the new version cannot be fetched.
#
# Bun's own bun.lock integrity hashes remain the enforcement mechanism for
# the actually-installed bytes (`bun install --frozen-lockfile` in the
# build); this JSON record is the reviewed provenance metadata layer on top.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="sync"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

# ── The single hand-editable version source ──────────────────────────────

ADAPTER_PACKAGE="@agentclientprotocol/claude-agent-acp"
ADAPTER_VERSION="0.77.0"
# The npm dist identity for ADAPTER_VERSION, part of the same source of
# truth: on a bump, fill both from `npm view <pkg>@<version> dist.integrity
# dist.shasum`. sync cross-checks them against the live registry whenever it
# can reach it; --check compares the committed record against these constants
# EXACTLY (a format-valid but wrong hand edit of the lock's dist fields fails).
ADAPTER_DIST_INTEGRITY="sha512-m8mhsAOc5+m/QZNsKCrfyIRv4KQrCLqSYHZP/aUvL3X0Xn0f9n4wKKNpOpOv0Kblh/2Mkpd4SW0KypN1dZkJfg=="
ADAPTER_DIST_SHASUM="ca57cfccd59a0057c6f81f4bde5dfbd90479950d"
ADAPTER_ENTRY_POINT="dist/index.js"
BUNDLE_NAME="claude-acp-adapter.js"

TOOL_DIR="tools/claude-acp-adapter"
PACKAGE_JSON="${TOOL_DIR}/package.json"
LOCKFILE="${TOOL_DIR}/bun.lock"
LOCK_JSON="${TOOL_DIR}/adapter.lock.json"
BUNDLE="Resources/claude-acp-adapter.bundle.js"
PIN_SWIFT="Sources/WikiFSEngine/VendoredAdapterPin.swift"
REGISTRY_URL="https://registry.npmjs.org"
TARBALL_URL="${REGISTRY_URL}/${ADAPTER_PACKAGE}/-/$(basename "${ADAPTER_PACKAGE}")-${ADAPTER_VERSION}.tgz"

run_bun() {
  if command -v bun >/dev/null 2>&1; then
    bun "$@"
  elif command -v mise >/dev/null 2>&1; then
    mise exec -- bun "$@"
  else
    return 127
  fi
}

bun_available() {
  run_bun --version >/dev/null 2>&1
}

# ── Generated-record writers ─────────────────────────────────────────────
#
# Each writer takes its OUTPUT path as $1 (compare-then-write: a no-op sync
# changes nothing on disk). sync calls them with the real tree paths; --check
# calls them with temp paths and byte-compares, so the committed records must
# match their generated form EXACTLY (an extra key, a changed comment, any
# hand edit at all fails).

write_package_json() {
  python3 - "$1" "$ADAPTER_PACKAGE" "$ADAPTER_VERSION" <<'PY'
import json, sys

path, spec, version = sys.argv[1:4]
document = {
    "name": "claude-acp-adapter-vendor",
    "version": "1.0.0",
    "private": True,
    "description": (
        "Vendor pin for @agentclientprotocol/claude-agent-acp, bundled to a single "
        "file executed by the resolved bun (`bun run <bundle>`). The dependency "
        "version is written by scripts/sync-acp-adapter.sh — never hand-edit it; "
        "change the version variable in the sync script and run "
        "`make acp-adapter-sync`. See plans/acp-adapter-vendoring.md."
    ),
    "type": "module",
    "scripts": {
        "build": "bun build.mjs",
        "verify": "bun verify.mjs",
    },
    "dependencies": {spec: version},
}
rendered = json.dumps(document, indent=2) + "\n"
current = open(path, encoding="utf-8").read() if __import__("os").path.exists(path) else None
if rendered != current:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(rendered)
PY
}

write_pin_swift() {
  python3 - "$1" "$ADAPTER_PACKAGE" "$ADAPTER_VERSION" "$BUNDLE_NAME" <<'PY'
import os, sys

path, spec, version, bundle_name = sys.argv[1:5]
content = f'''// Generated by scripts/sync-acp-adapter.sh — the compiled-in pin for the
// vendored Claude ACP adapter (issue #1257 Level 2). NEVER hand-edit: change
// ADAPTER_VERSION in the sync script and run `make acp-adapter-sync`, then
// review the generated diff. The version-bearing records
// (tools/claude-acp-adapter/adapter.lock.json,
// tools/claude-acp-adapter/package.json, and this file) are rewritten
// together from that one variable; a hand edit makes
// `scripts/sync-acp-adapter.sh --check` fail by design.

/// Compile-time pin for the vendored Claude ACP adapter bundle.
///
/// `ACPBackend` rewrites an adapter-shaped launch
/// (`bun x <spec>` / `bun x <spec>@<version>`) to run the committed
/// single-file bundle through the resolved bun when the spec matches
/// `vendoredAdapterPackageSpec` — bare, or pinned at exactly
/// `vendoredAdapterPinnedVersion`. Any other version keeps the configured
/// package-runner launch (the user asked for that version; the vendored
/// bundle is not it). `vendoredAdapterBundleName` names the file `build.sh`
/// stages into `Contents/Helpers`.
public enum VendoredAdapterPin {{
    /// The npm package spec the committed bundle was built from.
    public static let vendoredAdapterPackageSpec = "{spec}"

    /// The exact upstream version vendored into the committed bundle.
    public static let vendoredAdapterPinnedVersion = "{version}"

    /// The helper name `build.sh` stages into `Contents/Helpers`.
    public static let vendoredAdapterBundleName = "{bundle_name}"
}}
'''
current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
if content != current:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)
PY
}

# $1 = output path; $2 = dist.integrity; $3 = dist.shasum. The digest inputs
# are always the REAL tree files (the record describes the committed bytes).
write_lock_json() {
  python3 - "$1" "$ADAPTER_PACKAGE" "$ADAPTER_VERSION" "$ADAPTER_ENTRY_POINT" "$TARBALL_URL" "$BUNDLE" "$PACKAGE_JSON" "$LOCKFILE" "$2" "$3" <<'PY'
import hashlib, json, os, sys

path, package, version, entry, tarball, bundle, package_json, lockfile, integrity, shasum = sys.argv[1:11]

def sha256(rel):
    digest = hashlib.sha256()
    with open(rel, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()

document = {
    "comment": (
        "Generated provenance record for the vendored Claude ACP adapter "
        "(issue #1257 Level 2). Regenerate with scripts/sync-acp-adapter.sh; "
        "`--check` (no network, no bun) fails when this record, the committed "
        "bundle, or the version pins disagree."
    ),
    "package": package,
    "version": version,
    "entryPoint": entry,
    "tarballURL": tarball,
    "distIntegrity": integrity,
    "distShasum": shasum,
    "bundle": bundle,
    "fileDigests": {
        bundle: sha256(bundle),
        package_json: sha256(package_json),
        lockfile: sha256(lockfile),
    },
}
rendered = json.dumps(document, indent=2) + "\n"
current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
if rendered != current:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(rendered)
PY
}

committed_lock_version() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$LOCK_JSON" 2>/dev/null || true
}

# ── sync ─────────────────────────────────────────────────────────────────

if [[ "$MODE" == "sync" ]]; then
  committed_version="$(committed_lock_version)"
  version_changed=false
  if [[ "$committed_version" != "$ADAPTER_VERSION" ]]; then
    version_changed=true
  fi

  write_package_json "$PACKAGE_JSON"
  write_pin_swift "$PIN_SWIFT"

  # The dist identity is AUTHORED here (constants above) and cross-checked
  # against the live registry whenever it is reachable — so a mistyped
  # constant (or a registry-side surprise for the same version) is caught at
  # sync time, and --check can verify the committed record against the
  # constants EXACTLY with no network.
  encoded_spec="${ADAPTER_PACKAGE//\//%2F}"
  packument="$(curl -fsSL --max-time 30 "${REGISTRY_URL}/${encoded_spec}/${ADAPTER_VERSION}" 2>/dev/null || true)"
  if [[ -n "$packument" ]]; then
    registry_integrity="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dist"]["integrity"])' <<<"$packument" 2>/dev/null || true)"
    registry_shasum="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dist"]["shasum"])' <<<"$packument" 2>/dev/null || true)"
    if [[ "$registry_integrity" != "$ADAPTER_DIST_INTEGRITY" || "$registry_shasum" != "$ADAPTER_DIST_SHASUM" ]]; then
      echo "error: registry metadata for ${ADAPTER_PACKAGE}@${ADAPTER_VERSION} disagrees with the constants in this script" >&2
      echo "       constants : integrity=${ADAPTER_DIST_INTEGRITY:0:20}… shasum=${ADAPTER_DIST_SHASUM:0:12}…" >&2
      echo "       registry  : integrity=${registry_integrity:0:20}… shasum=${registry_shasum:0:12}…" >&2
      echo "       fix ADAPTER_DIST_INTEGRITY / ADAPTER_DIST_SHASUM (npm view), then re-run" >&2
      exit 1
    fi
  elif [[ "$version_changed" == true ]]; then
    echo "error: the version changed (${committed_version:-<none>} → ${ADAPTER_VERSION}) and the registry is unreachable — a bump needs the network to confirm the new dist identity" >&2
    exit 1
  else
    echo "note: npm registry unreachable — using the script's dist constants for the unchanged pin ${ADAPTER_VERSION}" >&2
  fi

  bundle_state="rebuilt"
  if bun_available; then
    build_args=(build.mjs)
    if [[ "$version_changed" == true ]]; then
      # A bump must let bun rewrite bun.lock from the new pin; the normal
      # path installs --frozen-lockfile so the committed lock is enforced.
      build_args+=(--update-lock)
    fi
    ( cd "$TOOL_DIR" && run_bun "${build_args[@]}" )
  else
    if [[ -f "$BUNDLE" && -f "$LOCKFILE" && "$version_changed" == false ]]; then
      bundle_state="kept"
      echo "note: bun is absent — keeping the committed bundle + lockfile" >&2
    else
      echo "error: bun is absent and the adapter bundle cannot be built" >&2
      if [[ "$version_changed" == true ]]; then
        echo "       the version changed (${committed_version:-<none>} → ${ADAPTER_VERSION}); install bun and re-run" >&2
      else
        echo "       install bun (https://bun.sh, or mise) and re-run" >&2
      fi
      exit 1
    fi
  fi

  write_lock_json "$LOCK_JSON" "$ADAPTER_DIST_INTEGRITY" "$ADAPTER_DIST_SHASUM"
  echo "✓ acp adapter synced (${ADAPTER_PACKAGE}@${ADAPTER_VERSION}, bundle ${bundle_state})"
  exit 0
fi

# ── check (no network, no bun) ───────────────────────────────────────────
#
# Two layers:
# 1. A python pass re-derives every generated VALUE from the constants and
#    compares against the tree — precise per-field error messages.
# 2. The writers then re-render all three generated records into a temp dir
#    and BYTE-compare them with the committed files — the exhaustive
#    backstop that catches any hand edit the value checks would miss
#    (extra keys, changed comments, formatting drift).

status=0
render_fail() {
  echo "error: $1" >&2
  echo "       run: scripts/sync-acp-adapter.sh" >&2
  status=1
}

python3 - "$LOCK_JSON" "$PACKAGE_JSON" "$LOCKFILE" "$BUNDLE" "$PIN_SWIFT" \
  "$ADAPTER_PACKAGE" "$ADAPTER_VERSION" "$ADAPTER_ENTRY_POINT" "$TARBALL_URL" "$BUNDLE_NAME" \
  "$ADAPTER_DIST_INTEGRITY" "$ADAPTER_DIST_SHASUM" <<'PY'
import hashlib, json, sys

lock_json, package_json, lockfile, bundle, pin_swift, spec, version, entry, tarball, bundle_name, integrity, shasum = sys.argv[1:13]
failures = []

def fail(message, hint="scripts/sync-acp-adapter.sh"):
    failures.append(message)
    print(f"error: {message}", file=sys.stderr)
    print(f"       run: {hint}", file=sys.stderr)

def sha256(rel):
    digest = hashlib.sha256()
    with open(rel, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()

lock = None
try:
    with open(lock_json, encoding="utf-8") as handle:
        lock = json.load(handle)
except FileNotFoundError:
    fail(f"{lock_json} is missing")
except json.JSONDecodeError as err:
    fail(f"{lock_json} is not valid JSON: {err}")

if lock is not None:
    if lock.get("version") != version:
        fail(
            f"version variable ({version}) != {lock_json} version ({lock.get('version')!r})"
            " — the pin changed without a re-sync"
        )
    if lock.get("package") != spec:
        fail(f"{lock_json} package is {lock.get('package')!r}, expected {spec!r}")
    if lock.get("entryPoint") != entry:
        fail(f"{lock_json} entryPoint is {lock.get('entryPoint')!r}, expected {entry!r}")
    if lock.get("tarballURL") != tarball:
        fail(f"{lock_json} tarballURL does not match the canonical registry URL for {version}")
    # Exact comparison against the authored constants: a format-valid but
    # wrong dist identity in the committed record fails here.
    if lock.get("distIntegrity") != integrity:
        fail(f"{lock_json} distIntegrity does not match ADAPTER_DIST_INTEGRITY")
    if lock.get("distShasum") != shasum:
        fail(f"{lock_json} distShasum does not match ADAPTER_DIST_SHASUM")

    digests = lock.get("fileDigests")
    if not isinstance(digests, dict) or not digests:
        fail(f"{lock_json} has no fileDigests")
    else:
        for rel, expected in sorted(digests.items()):
            try:
                actual = sha256(rel)
            except FileNotFoundError:
                fail(f"{rel} is missing (recorded in {lock_json})")
                continue
            if actual != expected:
                fail(
                    f"{rel} changed without a re-sync"
                    f" (digest {expected[:12]}… → {actual[:12]}…)"
                )
        for required in (bundle, package_json, lockfile):
            if required not in digests:
                fail(f"{lock_json} fileDigests does not cover {required}")

try:
    with open(package_json, encoding="utf-8") as handle:
        package = json.load(handle)
    pin = package.get("dependencies", {}).get(spec)
    if pin != version:
        fail(f"{package_json} pins {spec}@{pin!r}, expected {version!r} (generated record)")
except FileNotFoundError:
    fail(f"{package_json} is missing")
except json.JSONDecodeError as err:
    fail(f"{package_json} is not valid JSON: {err}")

try:
    with open(pin_swift, encoding="utf-8") as handle:
        swift = handle.read()
    for name, expected in (
        ("vendoredAdapterPackageSpec", spec),
        ("vendoredAdapterPinnedVersion", version),
        ("vendoredAdapterBundleName", bundle_name),
    ):
        literal = f'public static let {name} = "{expected}"'
        if literal not in swift:
            fail(f"{pin_swift} does not contain `{literal}` (generated record)")
except FileNotFoundError:
    fail(f"{pin_swift} is missing")

if failures:
    print(
        f"\n✗ acp adapter records are stale or disagreeing ({len(failures)} problem(s))",
        file=sys.stderr,
    )
    sys.exit(1)
print("✓ acp adapter record values are current")
PY

# Layer 2 — byte-exact render comparison. The writers run with temp output
# paths; every generated record must equal its generated form.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

write_package_json "${STAGE}/package.json"
write_pin_swift "${STAGE}/VendoredAdapterPin.swift"
write_lock_json "${STAGE}/adapter.lock.json" "$ADAPTER_DIST_INTEGRITY" "$ADAPTER_DIST_SHASUM"

for record in "package.json:$PACKAGE_JSON" "VendoredAdapterPin.swift:$PIN_SWIFT" "adapter.lock.json:$LOCK_JSON"; do
  rendered="${record%%:*}"
  committed="${record#*:}"
  if ! cmp -s "${STAGE}/${rendered}" "$committed"; then
    render_fail "$committed does not match its generated form (hand-edited, or stale generation)"
  fi
done

if [[ $status -ne 0 ]]; then
  echo "✗ acp adapter records are stale or disagreeing" >&2
  exit 1
fi
echo "✓ acp adapter records are current"
