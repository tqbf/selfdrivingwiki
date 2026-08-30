#!/usr/bin/env bash
#
# Generate the reviewed extractor packages under ExtractorPackages/ from their
# sources in tools/.
#
#   scripts/sync-extractor-packages.sh            regenerate in place
#   scripts/sync-extractor-packages.sh --check    fail when the tree is stale
#
# The reviewed packages are build inputs: the app and the wikid XPC service
# both receive this tree, and the machine catalog records the exact digest of
# every declared file. A drift between tools/ and ExtractorPackages/ must fail
# a gate rather than ship bytes nobody reviewed.
#
# How staleness is detected
# -------------------------
# The pdf2md package is a copy plus a generated entry point, so `--check`
# regenerates it and compares bytes directly.
#
# The Defuddle package is a `bun build` bundle. Bun embeds its input paths as
# comments, so a rebuild is byte-identical only when it runs from the same
# absolute path. Comparing bundle bytes across machines would therefore report
# drift that does not exist. Instead the digest of every SOURCE input is
# recorded in ExtractorPackages/sources.lock.json and compared. That detects a
# source edit that was never regenerated, which is the drift that matters, and
# it is machine independent.
#
# The committed package bytes are checked separately, and more strictly, by
# ReviewedExtractorPackageTests: it runs the real validator over the tree, so a
# hand edit or a stale manifest digest fails there.
#
# Bundling Defuddle needs the globally installed `defuddle` npm package. When
# it is absent the committed bundle is kept and the step is reported.
#
# Bundling Docx2md needs `tools/docx2md/node_modules` (`cd tools/docx2md &&
# bun install`). Like Defuddle, its bun bundle is not byte-reproducible
# across machines, so --check compares the sources.lock digest only.

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

PACKAGES_DIR="ExtractorPackages"
LOCK_FILE="${PACKAGES_DIR}/sources.lock.json"
DEFUDDLE_SOURCE="tools/defuddle/extractor-protocol.js"
PDF2MD_SOURCE="tools/pdf2md/pdf2md"
DOCX2MD_SOURCE="tools/docx2md/extractor-protocol.js"

# A fixed, repository-relative build directory. Bun records its input path in
# the bundle, so a stable path keeps repeated local builds identical.
BUILD_DIR="tmp/extractor-packages-build"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

sha256() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

DEFUDDLE_SOURCE_DIGEST="$(sha256 "$DEFUDDLE_SOURCE")"
PDF2MD_SOURCE_DIGEST="$(sha256 "$PDF2MD_SOURCE")"
DOCX2MD_SOURCE_DIGEST="$(sha256 "$DOCX2MD_SOURCE")"
DOCLING_SOURCE="tools/docling-serve/docling_serve_extractor.py"
DOCLING_SOURCE_DIGEST="$(sha256 "$DOCLING_SOURCE")"

npm_defuddle_root() {
  printf '%s/.local/lib/node_modules/defuddle' "$HOME"
}

DEFUDDLE_VERSION="$(node -e 'process.stdout.write(require(process.env.HOME + "/.local/lib/node_modules/defuddle/package.json").version)' 2>/dev/null || true)"
if [[ -z "$DEFUDDLE_VERSION" ]] && [[ -f "${PACKAGES_DIR}/Defuddle/manifest.json" ]]; then
  DEFUDDLE_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "${PACKAGES_DIR}/Defuddle/manifest.json")"
fi
: "${DEFUDDLE_VERSION:?defuddle version could not be resolved}"

# The mammoth version recorded in sources.lock.json. Read from the installed
# node_modules; when they are absent (bundle-keep degradation), fall back to
# the committed lock so --check does not report phantom drift.
DOCX2MD_MAMMOTH_VERSION=""
if [[ -f "tools/docx2md/node_modules/mammoth/package.json" ]]; then
  DOCX2MD_MAMMOTH_VERSION="$(python3 -c 'import json; print(json.load(open("tools/docx2md/node_modules/mammoth/package.json"))["version"])')"
elif [[ -f "$LOCK_FILE" ]]; then
  DOCX2MD_MAMMOTH_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("mammothLibraryVersion") or "")' "$LOCK_FILE")"
fi

# ── Defuddle ─────────────────────────────────────────────────────────────

build_defuddle_bundle() {
  local destination="$1"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cp "$DEFUDDLE_SOURCE" "${BUILD_DIR}/entry.js"
  ln -sfn "${HOME}/.local/lib/node_modules" "${BUILD_DIR}/node_modules"
  mise exec -- bun build "${BUILD_DIR}/entry.js" \
    --outfile "${BUILD_DIR}/defuddle-extractor.js" --target=bun >/dev/null
  mkdir -p "$(dirname "$destination")"
  cp "${BUILD_DIR}/defuddle-extractor.js" "$destination"
  rm -rf "$BUILD_DIR"
}

write_defuddle_provenance() {
  local target="$1"
  local version="$2"
  local library_license
  library_license="$(npm_defuddle_root)/LICENSE"
  [ -f "$library_license" ] || { echo "missing Defuddle library license at $library_license" >&2; exit 1; }
  cp "$library_license" "${target}/LICENSE"
  cat > "${target}/PROVENANCE.md" <<EOF
# Reviewed package provenance

- Package: org.selfdrivingwiki.defuddle
- Version: ${version}
- Upstream library: defuddle ${version} (MIT, see LICENSE)
- Entry point: generated from tools/defuddle/extractor-protocol.js
- Bundle: \`mise exec -- bun build\` against the pinned library
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
EOF
}

write_defuddle_manifest() {
  python3 - "$1" "$DEFUDDLE_VERSION" "$2" "$3" "$4" <<'PY'
import json, sys

path, version, digest, license_digest, provenance_digest = sys.argv[1:6]
manifest = {
    "manifestRevision": 1,
    "packageID": "org.selfdrivingwiki.defuddle",
    "version": version,
    "displayName": "Defuddle Article Extractor",
    "protocolRevision": 1,
    "entryPoint": "bin/defuddle-extractor.js",
    "launch": {"mode": "runtime", "command": "bun"},
    "registrations": [
        {
            "id": "article",
            "displayName": "Defuddle Article",
            "kinds": ["html"],
            "mimeTypes": ["text/html"],
        }
    ],
    # Local HTML extraction reads only the operation input file.
    "capabilities": [],
    "files": [
        {"path": "LICENSE", "digest": license_digest},
        {"path": "PROVENANCE.md", "digest": provenance_digest},
        {"path": "bin/defuddle-extractor.js", "digest": digest},
    ],
    "limits": {
        "maximumInputByteCount": 33554432,
        "maximumMarkdownOutputByteCount": 33554432,
        "maximumDurationMilliseconds": 120000,
        "maximumProgressEventCount": 64,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

# ── pdf2md ───────────────────────────────────────────────────────────────
#
# The host launches a runtime package as `<runtime> <fixed arguments>
# <entry point>`, so a trailing `--extractor-protocol` flag cannot be passed.
# Generate a thin entry point beside the script that calls its protocol
# function directly. Its PEP 723 block is copied from `pdf2md` so the two
# dependency lists cannot drift.

generate_pdf2md_package() {
  local target="$1"
  mkdir -p "${target}/bin"
  cp "$PDF2MD_SOURCE" "${target}/bin/pdf2md"

  python3 - "${target}/bin/pdf2md-extractor" "$PDF2MD_SOURCE" <<'PY'
import sys

destination, source = sys.argv[1], sys.argv[2]
lines = open(source, encoding="utf-8").read().splitlines()

# Copy the PEP 723 inline metadata block verbatim.
start = lines.index("# /// script")
end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "# ///")
metadata = "\n".join(lines[start:end + 1])

body = '''#!/usr/bin/env -S uv run --script
{metadata}
"""Extractor package entry point for pdf2md.

GENERATED by scripts/sync-extractor-packages.sh — do not edit.

The host launches this as `uv run --script <this file>`, so protocol mode
cannot be selected with a trailing flag. This entry point loads the reviewed
`pdf2md` script beside it and serves one request.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
from pathlib import Path

# The package directory is an immutable, digest-verified snapshot. Writing
# bytecode beside the script would add an undeclared file and invalidate it.
sys.dont_write_bytecode = True

_SCRIPT = Path(__file__).resolve().parent / "pdf2md"
_spec = importlib.util.spec_from_loader(
    "pdf2md", importlib.machinery.SourceFileLoader("pdf2md", str(_SCRIPT))
)
assert _spec is not None and _spec.loader is not None
_pdf2md = importlib.util.module_from_spec(_spec)
sys.modules["pdf2md"] = _pdf2md
_spec.loader.exec_module(_pdf2md)

sys.exit(_pdf2md.run_extractor_protocol(sys.stdin.read()))
'''.format(metadata=metadata)

with open(destination, "w", encoding="utf-8") as handle:
    handle.write(body)
PY

  cat > "${target}/PROVENANCE.md" <<'EOF'
# Reviewed package provenance

- Package: org.selfdrivingwiki.pdf2md
- Version: 1.0.0
- Source: tools/pdf2md/pdf2md in this repository
- Entry point: bin/pdf2md-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the script
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
EOF

  local script_digest entry_digest provenance_digest
  script_digest="$(sha256 "${target}/bin/pdf2md")"
  entry_digest="$(sha256 "${target}/bin/pdf2md-extractor")"
  provenance_digest="$(sha256 "${target}/PROVENANCE.md")"

  python3 - "${target}/manifest.json" "$script_digest" "$entry_digest" "$provenance_digest" <<'PY'
import json, sys

path, script_digest, entry_digest, provenance_digest = sys.argv[1:5]
manifest = {
    "manifestRevision": 1,
    "packageID": "org.selfdrivingwiki.pdf2md",
    "version": "1.0.0",
    "displayName": "Local pdf2md",
    "protocolRevision": 1,
    "entryPoint": "bin/pdf2md-extractor",
    "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
    "registrations": [
        {
            "id": "document",
            "displayName": "pdf2md Document",
            "kinds": ["pdf"],
            "mimeTypes": ["application/pdf"],
        }
    ],
    # uv resolves dependencies and docling downloads its model on first use.
    "capabilities": ["model-download", "network", "shared-runtime-cache"],
    "files": [
        {"path": "PROVENANCE.md", "digest": provenance_digest},
        {"path": "bin/pdf2md", "digest": script_digest},
        {"path": "bin/pdf2md-extractor", "digest": entry_digest},
    ],
    "limits": {
        "maximumInputByteCount": 134217728,
        "maximumMarkdownOutputByteCount": 33554432,
        "maximumDurationMilliseconds": 1800000,
        "maximumProgressEventCount": 1024,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

generate_docling_package() {
  local target="$1"
  mkdir -p "${target}/bin"
  cp "$DOCLING_SOURCE" "${target}/bin/docling_serve_extractor.py"

  python3 - "${target}/bin/docling-serve-extractor" <<'PY'
body = '''#!/usr/bin/env python3
"""Extractor package entry point for Docling Serve.

GENERATED by scripts/sync-extractor-packages.sh — do not edit.

The host launches this directly (direct launch mode), so the script reads the
protocol request from stdin. This entry point loads the reviewed
`docling_serve_extractor` module beside it and serves one request.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
from pathlib import Path

# The package directory is an immutable, digest-verified snapshot. Writing
# bytecode beside the script would add an undeclared file and invalidate it.
sys.dont_write_bytecode = True

_SCRIPT = Path(__file__).resolve().parent / "docling_serve_extractor.py"
_spec = importlib.util.spec_from_loader(
    "docling_serve_extractor",
    importlib.machinery.SourceFileLoader("docling_serve_extractor", str(_SCRIPT)),
)
assert _spec is not None and _spec.loader is not None
_module = importlib.util.module_from_spec(_spec)
sys.modules["docling_serve_extractor"] = _module
_spec.loader.exec_module(_module)

sys.exit(_module.run(sys.stdin.read()))
'''

with open(destination := __import__("sys").argv[1], "w", encoding="utf-8") as handle:
    handle.write(body)
PY
  chmod 0500 "${target}/bin/docling-serve-extractor"
  chmod 0400 "${target}/bin/docling_serve_extractor.py"

  cat > "${target}/PROVENANCE.md" <<'EOF'
# Reviewed package provenance

- Package: org.selfdrivingwiki.docling-serve
- Version: 1.0.0
- Implementation: first-party Python (standard library only), maintained in
  this repository at tools/docling-serve/docling_serve_extractor.py
- Entry point: generated wrapper that loads the reviewed module beside it
- Upstream service: Docling Serve (self-hosted; this package ships no
  third-party code)
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
EOF

  local module_digest entry_digest provenance_digest
  module_digest="$(sha256 "${target}/bin/docling_serve_extractor.py")"
  entry_digest="$(sha256 "${target}/bin/docling-serve-extractor")"
  provenance_digest="$(sha256 "${target}/PROVENANCE.md")"

  python3 - "${target}/manifest.json" "$module_digest" "$entry_digest" "$provenance_digest" <<'PY'
import json, sys

path, module_digest, entry_digest, provenance_digest = sys.argv[1:5]
manifest = {
    "manifestRevision": 2,
    "packageID": "org.selfdrivingwiki.docling-serve",
    "version": "1.0.0",
    "displayName": "Docling Serve",
    "protocolRevision": 2,
    "entryPoint": "bin/docling-serve-extractor",
    "launch": {"mode": "direct"},
    "registrations": [
        {
            "id": "document",
            "displayName": "Docling Serve document",
            "kinds": ["pdf"],
            "mimeTypes": ["application/pdf"],
            "credentialRequirements": [
                {
                    "id": "api-token",
                    "kind": "secret",
                    "optional": True,
                    "label": "Docling Serve API token",
                    "purpose": (
                        "Sent only as the X-Api-Key header when your Docling "
                        "Serve requires authentication."
                    ),
                }
            ],
        }
    ],
    "capabilities": ["network"],
    "files": [
        {"path": "PROVENANCE.md", "digest": provenance_digest},
        {"path": "bin/docling-serve-extractor", "digest": entry_digest},
        {"path": "bin/docling_serve_extractor.py", "digest": module_digest},
    ],
    "limits": {
        "maximumInputByteCount": 134217728,
        "maximumMarkdownOutputByteCount": 33554432,
        "maximumDurationMilliseconds": 1800000,
        "maximumProgressEventCount": 1024,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

write_lock_file() {
  python3 - "$1" "$DEFUDDLE_SOURCE_DIGEST" "$PDF2MD_SOURCE_DIGEST" "$DOCX2MD_SOURCE_DIGEST" "$DOCLING_SOURCE_DIGEST" "$DEFUDDLE_VERSION" "$DOCX2MD_MAMMOTH_VERSION" <<'PY'
import json, sys

path, defuddle_source, pdf2md_source, docx2md_source, docling_source, defuddle_version, mammoth_version = sys.argv[1:8]
lock = {
    "comment": (
        "Digests of the sources the reviewed packages are generated from. "
        "Regenerate with scripts/sync-extractor-packages.sh."
    ),
    "defuddleLibraryVersion": defuddle_version,
    "mammothLibraryVersion": mammoth_version or None,
    "sources": {
        "tools/defuddle/extractor-protocol.js": defuddle_source,
        "tools/pdf2md/pdf2md": pdf2md_source,
        "tools/docx2md/extractor-protocol.js": docx2md_source,
        "tools/docling-serve/docling_serve_extractor.py": docling_source,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(lock, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

# ── Docx2md ──────────────────────────────────────────────────────────────
#
# Bun bundle of tools/docx2md/extractor-protocol.js against the pinned
# dependencies in tools/docx2md/node_modules. Like the Defuddle bundle, the
# output embeds input paths, so bytes are only reproducible from the same
# absolute path; --check therefore uses the sources.lock digest strategy for
# this package and the committed bytes are policed by the validator tests.

build_docx_bundle() {
  local destination="$1"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cp "$DOCX2MD_SOURCE" "${BUILD_DIR}/entry.js"
  ln -sfn "$ROOT/tools/docx2md/node_modules" "${BUILD_DIR}/node_modules"
  mise exec -- bun build "${BUILD_DIR}/entry.js" \
    --outfile "${BUILD_DIR}/docx2md-extractor.js" --target=bun >/dev/null
  mkdir -p "$(dirname "$destination")"
  cp "${BUILD_DIR}/docx2md-extractor.js" "$destination"
  rm -rf "$BUILD_DIR"
}

write_docx_provenance() {
  local target="$1"
  local licenses_dir="${target}/licenses"
  mkdir -p "$licenses_dir"
  # Vendored upstream licenses are part of the reviewed payload: a missing
  # file is a hard error, mirroring the Defuddle license rule.
  local mammoth_license turndown_license gfm_license
  mammoth_license="$ROOT/tools/docx2md/node_modules/mammoth/LICENSE"
  turndown_license="$ROOT/tools/docx2md/node_modules/turndown/LICENSE"
  gfm_license="$ROOT/tools/docx2md/node_modules/turndown-plugin-gfm/LICENSE"
  [ -f "$mammoth_license" ] || { echo "missing mammoth license at $mammoth_license" >&2; echo "       run: cd tools/docx2md && bun install" >&2; exit 1; }
  [ -f "$turndown_license" ] || { echo "missing turndown license at $turndown_license" >&2; echo "       run: cd tools/docx2md && bun install" >&2; exit 1; }
  [ -f "$gfm_license" ] || { echo "missing turndown-plugin-gfm license at $gfm_license" >&2; echo "       run: cd tools/docx2md && bun install" >&2; exit 1; }
  cp "$mammoth_license" "${licenses_dir}/mammoth-LICENSE"
  cp "$turndown_license" "${licenses_dir}/turndown-LICENSE"
  cp "$gfm_license" "${licenses_dir}/turndown-plugin-gfm-LICENSE"
  cat > "${target}/PROVENANCE.md" <<EOF
# Reviewed package provenance

- Package: org.selfdrivingwiki.docx2md
- Version: 1.0.0
- Upstream libraries: mammoth ${DOCX2MD_MAMMOTH_VERSION} (BSD-2-Clause, see
  licenses/mammoth-LICENSE), turndown (MIT, see licenses/turndown-LICENSE),
  turndown-plugin-gfm (MIT, see licenses/turndown-plugin-gfm-LICENSE)
- Entry point: generated from tools/docx2md/extractor-protocol.js
- Table rules: adapted from turndown-plugin-gfm (MIT) with a
  first-row-as-header fallback and mammoth cell cleanup
- Bundle: \`mise exec -- bun build --target=bun\` against the pinned
  dependencies
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
EOF
}

write_docx_manifest() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys

path, bundle_digest, provenance_digest, mammoth_license_digest, turndown_license_digest, gfm_license_digest = sys.argv[1:7]
manifest = {
    "manifestRevision": 1,
    "packageID": "org.selfdrivingwiki.docx2md",
    "version": "1.0.0",
    "displayName": "Local docx2md",
    "protocolRevision": 1,
    "entryPoint": "bin/docx2md-extractor.js",
    "launch": {"mode": "runtime", "command": "bun"},
    "registrations": [
        {
            "id": "document",
            "displayName": "docx2md Document",
            "kinds": ["docx"],
            "mimeTypes": ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
            "filenameExtensions": ["docx"],
        }
    ],
    # Local conversion reads only the operation input file; mammoth and
    # turndown are fully offline.
    "capabilities": [],
    "files": [
        {"path": "PROVENANCE.md", "digest": provenance_digest},
        {"path": "bin/docx2md-extractor.js", "digest": bundle_digest},
        {"path": "licenses/mammoth-LICENSE", "digest": mammoth_license_digest},
        {"path": "licenses/turndown-LICENSE", "digest": turndown_license_digest},
        {"path": "licenses/turndown-plugin-gfm-LICENSE", "digest": gfm_license_digest},
    ],
    "limits": {
        "maximumInputByteCount": 33554432,
        "maximumMarkdownOutputByteCount": 33554432,
        "maximumDurationMilliseconds": 120000,
        "maximumProgressEventCount": 64,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

# ── Run ──────────────────────────────────────────────────────────────────

status=0

if [[ "$MODE" == "sync" ]]; then
  if [[ -d "${HOME}/.local/lib/node_modules/defuddle" ]]; then
    build_defuddle_bundle "${PACKAGES_DIR}/Defuddle/bin/defuddle-extractor.js"
    bundle_state="rebuilt"
  elif [[ -f "${PACKAGES_DIR}/Defuddle/bin/defuddle-extractor.js" ]]; then
    echo "note: defuddle npm package is absent — keeping the committed bundle" >&2
    bundle_state="kept"
  else
    echo "error: defuddle npm package is absent and no bundle is committed" >&2
    echo "       run: npm install -g defuddle" >&2
    exit 1
  fi
  write_defuddle_provenance "${PACKAGES_DIR}/Defuddle" "$DEFUDDLE_VERSION"
  write_defuddle_manifest \
    "${PACKAGES_DIR}/Defuddle/manifest.json" \
    "$(sha256 "${PACKAGES_DIR}/Defuddle/bin/defuddle-extractor.js")" \
    "$(sha256 "${PACKAGES_DIR}/Defuddle/LICENSE")" \
    "$(sha256 "${PACKAGES_DIR}/Defuddle/PROVENANCE.md")"

  rm -rf "${PACKAGES_DIR}/Pdf2md"
  generate_pdf2md_package "${PACKAGES_DIR}/Pdf2md"
  rm -rf "${PACKAGES_DIR}/DoclingServe"
  generate_docling_package "${PACKAGES_DIR}/DoclingServe"

  if [[ -d "tools/docx2md/node_modules" ]]; then
    rm -rf "${PACKAGES_DIR}/Docx2md"
    mkdir -p "${PACKAGES_DIR}/Docx2md/bin"
    build_docx_bundle "${PACKAGES_DIR}/Docx2md/bin/docx2md-extractor.js"
    write_docx_provenance "${PACKAGES_DIR}/Docx2md"
    write_docx_manifest \
      "${PACKAGES_DIR}/Docx2md/manifest.json" \
      "$(sha256 "${PACKAGES_DIR}/Docx2md/bin/docx2md-extractor.js")" \
      "$(sha256 "${PACKAGES_DIR}/Docx2md/PROVENANCE.md")" \
      "$(sha256 "${PACKAGES_DIR}/Docx2md/licenses/mammoth-LICENSE")" \
      "$(sha256 "${PACKAGES_DIR}/Docx2md/licenses/turndown-LICENSE")" \
      "$(sha256 "${PACKAGES_DIR}/Docx2md/licenses/turndown-plugin-gfm-LICENSE")"
    docx_state="rebuilt"
  elif [[ -f "${PACKAGES_DIR}/Docx2md/bin/docx2md-extractor.js" ]]; then
    echo "note: tools/docx2md/node_modules is absent — keeping the committed Docx2md bundle" >&2
    docx_state="kept"
  else
    echo "error: tools/docx2md/node_modules is absent and no Docx2md bundle is committed" >&2
    echo "       run: cd tools/docx2md && bun install" >&2
    exit 1
  fi
  write_lock_file "$LOCK_FILE"
  echo "✓ extractor packages synced (defuddle ${DEFUDDLE_VERSION}, bundle ${bundle_state}, docx ${docx_state})"
  exit 0
fi

# check mode
if [[ ! -f "$LOCK_FILE" ]]; then
  echo "error: ${LOCK_FILE} is missing — run scripts/sync-extractor-packages.sh" >&2
  exit 1
fi

write_lock_file "${STAGE}/sources.lock.json"
if ! diff -q "${STAGE}/sources.lock.json" "$LOCK_FILE" >/dev/null 2>&1; then
  echo "error: reviewed package sources changed without regeneration" >&2
  diff "$LOCK_FILE" "${STAGE}/sources.lock.json" >&2 || true
  echo "       run: scripts/sync-extractor-packages.sh" >&2
  status=1
fi

generate_pdf2md_package "${STAGE}/Pdf2md"
if ! diff -r -q "${STAGE}/Pdf2md" "${PACKAGES_DIR}/Pdf2md" >/dev/null 2>&1; then
  echo "error: ${PACKAGES_DIR}/Pdf2md is stale" >&2
  diff -r -q "${STAGE}/Pdf2md" "${PACKAGES_DIR}/Pdf2md" >&2 || true
  echo "       run: scripts/sync-extractor-packages.sh" >&2
  status=1
fi

# DoclingServe is generated (copy + generated entry point), so --check
# regenerates and compares bytes directly, like Pdf2md (PR 4 review
# MEDIUM-4: source-lock comparison alone cannot prove generated files are
# current).
generate_docling_package "${STAGE}/DoclingServe"
if ! diff -r -q "${STAGE}/DoclingServe" "${PACKAGES_DIR}/DoclingServe" >/dev/null 2>&1; then
  echo "error: ${PACKAGES_DIR}/DoclingServe is stale" >&2
  diff -r -q "${STAGE}/DoclingServe" "${PACKAGES_DIR}/DoclingServe" >&2 || true
  echo "       run: scripts/sync-extractor-packages.sh" >&2
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "✓ extractor packages are current"
fi
exit $status
