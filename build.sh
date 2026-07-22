#!/usr/bin/env bash
#
# build.sh — compile Self Driving Wiki + its File Provider extension, bundle
# them into a proper macOS .app (with the .appex nested under Contents/PlugIns),
# embed provisioning profiles, and codesign inside-out.
#
#   ./build.sh [debug|release]
#
# Driven by the Makefile. NOT an Xcode/xcodebuild build: `swift build` produces
# the two binaries, this script does the bundling/signing Xcode would hide.
#
# Signing modes:
#   * Real (dev cert in keychain + profiles in signing/): full inside-out sign
#     with per-bundle entitlements + embedded profiles. Required for the File
#     Provider extension to load.
#   * Ad-hoc fallback (no cert): app still bundles/launches, but the extension
#     will NOT register as a File Provider. Fine for Phase 0/1 UI work.
#
# Identity selection is CONFIG-aware (#746): debug builds use DEV_IDENTITY
# (Apple Development, local-only) and release builds use DIST_IDENTITY
# (Developer ID Application, for distribution / notarization). The Makefile
# passes the right one via SIGN_IDENTITY; see plans/fix-signing-cert.md.
#
set -euo pipefail

CONFIG="${1:-debug}"

# Per-developer signing identifiers + dev identity. The defaults below are the
# upstream author's; bundle ids and App Groups are GLOBALLY UNIQUE across App
# Store Connect and cannot be reused, so anyone building against their own Apple
# Developer account overrides them via signing/local.config (gitignored). Write
# it from signing/local.config.example by hand, or generate the whole signing
# setup with signing/setup.sh. See plans/signing.md.
LOCAL_CONFIG="signing/local.config"
# shellcheck disable=SC1090
[ -f "${LOCAL_CONFIG}" ] && . "${LOCAL_CONFIG}"

APP_NAME="Self Driving Wiki"
APP_TARGET_NAME="WikiFS"
EXT_NAME="WikiFSFileProvider"
CTL_NAME="wikictl"
# wikid — the XPC daemon (plans/multi-wiki-daemon.md). Bundled under
# Contents/Helpers so launchd can run it with the app's signing identity
# (avoids kTCCServiceSystemPolicyAppData prompts — a standalone .build binary
# has a different cdhash per rebuild, invalidating TCC trust each time).
DAEMON_NAME="wikid"
# podcast-token-helper: the FairPlay/Mescal signer for Apple Podcasts transcripts
# (dlopens the private PodcastsFoundation framework in an isolated process). Bundled
# under Contents/Helpers beside wikictl; WikiFSCore spawns it via Process. Private
# API — dev-signed / local only. See plans/podcast-transcripts.md.
PODCAST_HELPER_NAME="podcast-token-helper"
PDF2MD_NAME="pdf2md"
PDF2MD_SRC="tools/pdf2md/pdf2md"
DEFUDDLE_NAME="defuddle"
DEFUDDLE_SRC="tools/defuddle/defuddle"
BUNDLE_ID="${BUNDLE_ID:-org.sockpuppet.WikiFS}"
EXT_BUNDLE_ID="${EXT_BUNDLE_ID:-org.sockpuppet.WikiFS.FileProvider}"
APP_GROUP="${APP_GROUP:-group.org.sockpuppet.wiki}"
TEAM_ID="${TEAM_ID:-KK7E9G89GW}"
MIN_MACOS="14.0"

APP_PROFILE="signing/WikiFS.provisionprofile"
EXT_PROFILE="signing/WikiFSFileProvider.provisionprofile"
APP_ICON="build/AppIcon.icns"

BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
PLUGINS_DIR="${CONTENTS}/PlugIns"
APPEX="${PLUGINS_DIR}/${EXT_NAME}.appex"
APPEX_CONTENTS="${APPEX}/Contents"
APPEX_MACOS="${APPEX_CONTENTS}/MacOS"
# wikictl is embedded under Contents/Helpers so the app can spawn it (Phase C)
# at a stable bundle-relative path; it is ALSO copied to build/wikictl for the
# Phase A gate to invoke directly.
HELPERS_DIR="${CONTENTS}/Helpers"

# Entitlements are GENERATED into build/ from the identifiers above, so the team
# prefix + App Group always track signing/local.config (no stale committed file
# baked to one developer's team). Written just before codesign.
APP_ENTITLEMENTS="${BUILD_DIR}/WikiFS.entitlements"
EXT_ENTITLEMENTS="${BUILD_DIR}/WikiFSFileProvider.entitlements"

VERSION="$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
if [ -z "${VERSION}" ] && [ -f VERSION ]; then VERSION="$(sed -n '1p' VERSION | tr -d '[:space:]')"; fi
VERSION="${VERSION:-0.0.0}"

# Build identifier: commit count + short SHA (e.g. "423-abc1234"). Monotone
# integer for Apple's build-number expectations, with the SHA baked in for
# traceability. Goes into CFBundleVersion (separate from the marketing
# VERSION above, which goes into CFBundleShortVersionString).
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_COMMIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
BUILD_VERSION="${GIT_COMMIT_COUNT}-${GIT_SHA}"

# ---------------------------------------------------------------------------
# Up-front prerequisite gate: bun (fail fast BEFORE the Swift compile)
# ---------------------------------------------------------------------------
# The bundling section (~L132) copies the resolved bun binary into helpers/,
# but that runs AFTER `swift build` — without this gate a developer missing
# bun waits through the full compile before discovering it. See #762.
# Resolution chain mirrors the bundling logic, with a PATH fallback.
BUN_SRC="${BUN_INSTALL:-$HOME/.bun}/bin/bun"
if [ ! -x "${BUN_SRC}" ]; then
  BUN_SRC="$(command -v bun 2>/dev/null || true)"
fi
if [ -z "${BUN_SRC}" ] || [ ! -x "${BUN_SRC}" ]; then
  echo "✗ FATAL: bun not found" >&2
  echo "    Install it:  curl -fsSL https://bun.sh/install | bash" >&2
  echo "    Or set BUN_INSTALL to point at your bun binary's directory." >&2
  exit 1
fi

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
APP_BIN="${BIN_DIR}/${APP_TARGET_NAME}"
EXT_BIN="${BIN_DIR}/${EXT_NAME}"
CTL_BIN="${BIN_DIR}/${CTL_NAME}"
DAEMON_BIN="${BIN_DIR}/${DAEMON_NAME}"
PODCAST_HELPER_BIN="${BIN_DIR}/${PODCAST_HELPER_NAME}"
for b in "${APP_BIN}" "${EXT_BIN}" "${CTL_BIN}" "${DAEMON_BIN}"; do
  [ -x "$b" ] || { echo "✗ built binary missing: $b" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Assemble the .app
# ---------------------------------------------------------------------------
echo "→ assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${APPEX_MACOS}" "${HELPERS_DIR}" "${CONTENTS}/Library/LaunchAgents"
cp "${APP_BIN}" "${MACOS_DIR}/${APP_NAME}"
cp "${EXT_BIN}" "${APPEX_MACOS}/${EXT_NAME}"
cp "${CTL_BIN}" "${HELPERS_DIR}/${CTL_NAME}"
# wikid daemon — bundled beside wikictl so launchd launches the SIGNED binary
# (inherits the app's TCC trust; a standalone .build binary prompts on every rebuild).
cp "${DAEMON_BIN}" "${HELPERS_DIR}/${DAEMON_NAME}"
# The SMAppService plist goes at Contents/Library/LaunchAgents/ so
# SMAppService.agent(plistName:) can find it. Uses BundleProgram (relative
# to the app bundle root) instead of ProgramArguments (absolute path).
cp signing/com.selfdrivingwiki.wikid.plist "${CONTENTS}/Library/LaunchAgents/com.selfdrivingwiki.wikid.plist"
# Also drop a copy at build/wikictl for the Phase A gate to invoke directly.
cp "${CTL_BIN}" "${BUILD_DIR}/${CTL_NAME}"
# podcast-token-helper alongside wikictl (spawned via Process for transcript
# ingest). Optional — a toolchain/App-Store config that can't build the ObjC
# target just omits it, and podcast ingest surfaces a clear "not available" message.
if [ -x "${PODCAST_HELPER_BIN}" ]; then
  cp "${PODCAST_HELPER_BIN}" "${HELPERS_DIR}/${PODCAST_HELPER_NAME}"
else
  echo "  (${PODCAST_HELPER_NAME} not found at ${PODCAST_HELPER_BIN} — Apple Podcasts transcript ingest will be unavailable)"
fi
# Bun runtime — bundled so ACP providers (claude-acp via bunx) work without a
# system-wide install. Resolved up-front (BUN_INSTALL → ~/.bun → PATH) and
# gated before the Swift compile; see #762. Here we just copy the already-
# resolved binary into helpers/. REQUIRED: if absent the build fails rather
# than shipping a broken app that errors at spawn time.
if [ -x "${BUN_SRC}" ]; then
  cp "${BUN_SRC}" "${HELPERS_DIR}/bun"
  echo "  ✓ bundled bun ($(file -b "${BUN_SRC}" | cut -d, -f1))"
else
  echo "  ✗ FATAL: bun not found at ${BUN_SRC}" >&2
  echo "    Install it:  curl -fsSL https://bun.sh/install | bash" >&2
  echo "    Or set BUN_INSTALL to point at your bun binary's directory." >&2
  exit 1
fi

# uv runtime — bundled so pdf2md (a PEP 723 inline script whose shebang is
# `env -S uv run --script`) works without a system-wide uv install. Same
# shape as bun: a single static binary (astral-sh/uv). PdfExtractionService
# prepends this Helpers dir to the subprocess PATH so the bundled uv is found
# first; the system-uv PATH fallbacks in uvSearchPATH remain as a safety net.
# REQUIRED: if absent the build fails rather than shipping a broken app that
# silently degrades PDF extraction to the agent Read tool. See #766.
UV_SRC="${UV_INSTALL:-$HOME/.local/bin}/uv"
if [ ! -x "${UV_SRC}" ]; then
  UV_SRC="$(command -v uv 2>/dev/null || true)"
fi
if [ -x "${UV_SRC}" ]; then
  cp "${UV_SRC}" "${HELPERS_DIR}/uv"
  echo "  ✓ bundled uv ($(file -b "${UV_SRC}" | cut -d, -f1))"
else
  echo "  ✗ FATAL: uv not found" >&2
  echo "    Install it:  curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  echo "    Or set UV_INSTALL to point at your uv binary's directory." >&2
  exit 1
fi
# wikictl is a plain CLI with no Info.plist, so it can't read the App Group id
# the way the .app/.appex do. Drop a sidecar that WikiIdentifiers reads. It must
# NOT live in Contents/Helpers (a code location — codesign rejects unsigned
# plain files there), so the bundled copy goes in Contents/Resources; wikictl
# resolves it via ../Resources. The build/ copy sits beside build/wikictl for
# the Phase A gate. See Sources/WikiFSCore/WikiIdentifiers.swift.
write_id_sidecar () {
  cat > "$1/wiki-identifiers.env" <<EOF
WIKI_APP_GROUP_ID=${APP_GROUP}
WIKI_FILE_PROVIDER_ID=${EXT_BUNDLE_ID}
EOF
}
write_id_sidecar "${RESOURCES_DIR}"
write_id_sidecar "${BUILD_DIR}"
# Bundle the pdf2md PEP 723 script alongside wikictl so PdfExtractionService
# can spawn it at ingest time.
if [ -f "${PDF2MD_SRC}" ]; then
  cp "${PDF2MD_SRC}" "${HELPERS_DIR}/${PDF2MD_NAME}"
  cp "${PDF2MD_SRC}" "${BUILD_DIR}/${PDF2MD_NAME}"
else
  echo "  (pdf2md not found at ${PDF2MD_SRC} — skipping; PDF extraction will fall back to agent Read tool)"
fi
# Bundle the defuddle readability extractor (Node script run via the bundled
# bun). Used by DefuddleExtractionService for HTML article markdown+metadata.
if [ -f "${DEFUDDLE_SRC}" ]; then
  cp "${DEFUDDLE_SRC}" "${HELPERS_DIR}/${DEFUDDLE_NAME}"
  cp "${DEFUDDLE_SRC}" "${BUILD_DIR}/${DEFUDDLE_NAME}"
else
  echo "  (defuddle not found at ${DEFUDDLE_SRC} — skipping; HTML extraction will fall back to tag-based)"
fi
# Semantic vector search is now pure Swift (`VectorCosine` in WikiFSSearch —
# issue #628): no C extension to copy, no per-connection registration.
# Vendored Mermaid v11.16.0 (UMD build). Used for BOTH rendering ```mermaid
# fenced blocks in the reader AND validating them at save time (#669 — replaces
# the third-party merval validator, eliminating version skew). Copied as
# mermaid.js (dropping the `.min`) so the Bundle lookup is a simple name=mermaid
# / ext=js — avoids a flaky double-extension resource lookup. A plain JS
# resource needs no separate codesign step (sealed by the outer .app), matching
# how wiki-identifiers.env is handled.
MERMAID_JS="Resources/mermaid.min.js"
if [ -f "${MERMAID_JS}" ]; then
  cp "${MERMAID_JS}" "${RESOURCES_DIR}/mermaid.js"
else
  echo "  (mermaid.min.js not found at ${MERMAID_JS} — mermaid blocks will render as code and save-time validation will be skipped)"
fi
# Vendored markdownlint (cosmetic markdown linter), bundled to a single
# self-contained IIFE. Copied as markdownlint.js so the loader's name/ext lookup
# is simple. Runs in a JavaScriptCore JSContext at save time — no Node at runtime.
MARKDOWNLINT_JS="Resources/markdownlint.bundle.js"
if [ -f "${MARKDOWNLINT_JS}" ]; then
  cp "${MARKDOWNLINT_JS}" "${RESOURCES_DIR}/markdownlint.js"
else
  echo "  (markdownlint.bundle.js not found at ${MARKDOWNLINT_JS} — markdown save-time auto-fix will be skipped)"
fi
# Bundled snapshot of the official ACP agent registry (#665) — the offline
# fallback for `ACPRegistryClient.loadAgents()` (served when both the cache
# and the live fetch fail). Cached at runtime under Application Support; this
# is the shipped-last-resort. Plain JSON, codesigned with the outer .app.
ACP_REGISTRY_JSON="Resources/acp-registry.json"
if [ -f "${ACP_REGISTRY_JSON}" ]; then
  cp "${ACP_REGISTRY_JSON}" "${RESOURCES_DIR}/acp-registry.json"
else
  echo "  (acp-registry.json not found at ${ACP_REGISTRY_JSON} — registry will fall back to the hardcoded catalog)"
fi
# MLX runtime — model dir + metallib, both downloaded on demand (gitignored),
# bundled into the .app. The metallib is REQUIRED: swift build can't build MLX's
# Metal shaders, so the prebuilt version-matched one (fetched by download.py) must
# ship next to the binary (MLX's loader finds it via the bundle Resources path).
if [ ! -d "Resources/all-MiniLM-L6-v2" ] || [ ! -f "Resources/mlx.metallib" ]; then
  echo "  MLX runtime absent — running prepare step (tools/minilm-prepare/download.py) ..."
  ( cd tools/minilm-prepare && uv run python download.py )
fi
if [ -d "Resources/all-MiniLM-L6-v2" ]; then
  echo "  Bundling all-MiniLM-L6-v2 ..."
  cp -r "Resources/all-MiniLM-L6-v2" "${RESOURCES_DIR}/all-MiniLM-L6-v2"
fi
if [ -f "Resources/mlx.metallib" ]; then
  echo "  Bundling mlx.metallib ..."
  cp "Resources/mlx.metallib" "${RESOURCES_DIR}/mlx.metallib"
  # MLX's C++ load_default_library searches for the metallib RELATIVE TO THE
  # BINARY (<binary_dir>/mlx.metallib, then <binary_dir>/Resources/mlx.metallib)
  # — NOT via NSBundle resource lookup. The binary lives in Contents/MacOS/, so
  # a Contents/Resources/mlx.metallib (the macOS-standard, properly-signed-as-a-
  # resource location) is NEVER found → MLX's default error handler calls exit()
  # and silently kills the app at first GPU use. A real file in Contents/MacOS/
  # breaks codesign (a metallib there is an unsigned code subobject), so symlink
  # it from next to the binary back into Resources. Metal's library loader follows
  # the symlink; codesign seals it by reference. (.build/debug already has the
  # metallib adjacent to the executable, which is why running it directly worked.)
  ln -sf "../Resources/mlx.metallib" "${MACOS_DIR}/mlx.metallib"
fi

[ -f "${APP_ICON}" ] && cp "${APP_ICON}" "${RESOURCES_DIR}/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
	<key>WIKIGitSHA</key><string>${GIT_SHA}</string>
	<key>WIKIGitCommitCount</key><string>${GIT_COMMIT_COUNT}</string>
	<key>WIKIBuildVersion</key><string>${BUILD_VERSION}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<!-- Per-developer ids read at runtime by WikiIdentifiers (Bundle.main path). -->
	<key>WIKIAppGroupID</key><string>${APP_GROUP}</string>
	<key>WIKIFileProviderID</key><string>${EXT_BUNDLE_ID}</string>
	<!-- Internal pasteboard type for sidebar drag-and-drop onto the welcome
	     screen / detail view (#133). Conforms to public.item (NOT public.data):
	     WKWebView and its internal subviews auto-register broad types like
	     public.data and re-register them after load, which intercepts any
	     payload that conforms to public.data before SwiftUI's dropDestination
	     sees it. A sibling under public.item doesn't conform to those broad
	     types, so sidebar drags bubble past the WKWebView to the drop target. -->
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>com.selfdrivingwiki.sidebar-item</string>
			<key>UTTypeDescription</key>
			<string>Self Driving Wiki sidebar item</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.item</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>sdw-sidebar-item</string>
				</array>
			</dict>
		</dict>
	</array>
</dict>
</plist>
PLIST

# Appex Info.plist. CFBundlePackageType=XPC! and the NSExtension dict are what
# make macOS treat this bundle as a replicated File Provider extension.
cat > "${APPEX_CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${EXT_NAME}</string>
	<key>CFBundleDisplayName</key><string>Self Driving Wiki File Provider</string>
	<key>CFBundleExecutable</key><string>${EXT_NAME}</string>
	<key>CFBundleIdentifier</key><string>${EXT_BUNDLE_ID}</string>
	<key>CFBundlePackageType</key><string>XPC!</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
		<key>NSExtensionPrincipalClass</key><string>FileProviderExtension</string>
		<key>NSExtensionFileProviderSupportsEnumeration</key><true/>
		<key>NSExtensionFileProviderDocumentGroup</key><string>${APP_GROUP}</string>
		<key>NSExtensionFileProviderEnabledByDefault</key><true/>
	</dict>
	<!-- Read at runtime by WikiIdentifiers (Bundle.main path) in the extension. -->
	<key>WIKIAppGroupID</key><string>${APP_GROUP}</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Codesign
# ---------------------------------------------------------------------------
# Identity precedence (#746):
#   * release (CONFIG=release): SIGN_IDENTITY env (Makefile passes
#     DIST_IDENTITY) → DIST_IDENTITY from signing/local.config → ad-hoc ("-").
#     Does NOT fall back to DEV_IDENTITY — a release built with the Apple
#     Development cert is the bug this fixes (#746); notarytool rejects it and
#     Gatekeeper rejects it on other machines. Ad-hoc "-" is the only fallback
#     (and `make sign` then re-signs the outer app with Developer ID + hardened
#     runtime + timestamp for notarization).
#   * debug/local (CONFIG=debug): SIGN_IDENTITY env (Makefile passes
#     DEV_IDENTITY) → DEV_IDENTITY from signing/local.config → ad-hoc ("-").
#     No DIST_IDENTITY fallback — a local debug build must never silently pick
#     up the distribution cert.
# See plans/fix-signing-cert.md.
if [ "${CONFIG}" = "release" ]; then
  IDENTITY="${SIGN_IDENTITY:-${DIST_IDENTITY:--}}"
else
  IDENTITY="${SIGN_IDENTITY:-${DEV_IDENTITY:--}}"
fi
if [ "${IDENTITY}" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
  echo "  (identity '${IDENTITY}' not in keychain — falling back to ad-hoc)"
  IDENTITY="-"
fi

REAL_SIGNING=0
if [ "${IDENTITY}" != "-" ] && [ -f "${APP_PROFILE}" ] && [ -f "${EXT_PROFILE}" ]; then
  REAL_SIGNING=1
fi

if [ "${REAL_SIGNING}" = "1" ]; then
  # Generate entitlements from the resolved identifiers. Each entitlement MUST be
  # a subset of what the embedded profile authorizes, or AMFI SIGKILLs at exec.
  echo "→ generating entitlements (team ${TEAM_ID}, group ${APP_GROUP})"
  cat > "${APP_ENTITLEMENTS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>${TEAM_ID}.${BUNDLE_ID}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${TEAM_ID}</string>
	<!-- App Group container holds the SQLite DB shared with the sandboxed File
	     Provider extension. The app accesses it via a LITERAL path (see
	     DatabaseLocation.appGroupContainerDirectory), but WITHOUT this entitlement
	     macOS treats the group container as "another app's data" and shows a
	     "would like to access data from other apps" privacy prompt at every cold
	     launch — which also holds the app in the background until dismissed. The
	     app's provisioning profile already authorizes this group. -->
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${APP_GROUP}</string>
	</array>
</dict>
</plist>
PLIST
  cat > "${EXT_ENTITLEMENTS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>${TEAM_ID}.${EXT_BUNDLE_ID}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${TEAM_ID}</string>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${APP_GROUP}</string>
	</array>
</dict>
</plist>
PLIST

  echo "→ embedding provisioning profiles"
  cp "${APP_PROFILE}" "${CONTENTS}/embedded.provisionprofile"
  cp "${EXT_PROFILE}" "${APPEX_CONTENTS}/embedded.provisionprofile"

  # Inside-out: sign nested Mach-O (the wikictl helper + the .appex) first, then
  # the outer app. wikictl needs no entitlements — it's an un-sandboxed helper
  # writing user-owned App Group files, launched by the un-sandboxed app.
  echo "→ codesign wikictl helper (${IDENTITY})"
  codesign --force --timestamp=none --sign "${IDENTITY}" \
    "${HELPERS_DIR}/${CTL_NAME}"
  # wikid daemon — same inside-out signing as wikictl. No entitlements needed
  # (un-sandboxed helper, inherits the app's TCC trust by being inside the bundle).
  echo "→ codesign wikid daemon (${IDENTITY})"
  codesign --force --timestamp=none \
    --identifier com.selfdrivingwiki.wikid \
    --sign "${IDENTITY}" \
    "${HELPERS_DIR}/${DAEMON_NAME}"
  # pdf2md is a plain script bundled in Helpers/ — must also be signed, or the
  # outer app's seal fails ("code object is not signed at all").
  if [ -f "${HELPERS_DIR}/${PDF2MD_NAME}" ]; then
    codesign --force --timestamp=none --sign "${IDENTITY}" \
      "${HELPERS_DIR}/${PDF2MD_NAME}"
  fi
  # defuddle is a plain script bundled in Helpers/ — must also be signed, or the
  # outer app's seal fails ("code object is not signed at all"). bun reads the
  # file; signing is for the seal (same reason as pdf2md above).
  if [ -f "${HELPERS_DIR}/${DEFUDDLE_NAME}" ]; then
    codesign --force --timestamp=none --sign "${IDENTITY}" \
      "${HELPERS_DIR}/${DEFUDDLE_NAME}"
  fi
  # podcast-token-helper is a nested Mach-O — sign it before the outer app (same
  # inside-out discipline as wikictl). Only present in a feature-on build.
  if [ -f "${HELPERS_DIR}/${PODCAST_HELPER_NAME}" ]; then
    codesign --force --timestamp=none --sign "${IDENTITY}" \
      "${HELPERS_DIR}/${PODCAST_HELPER_NAME}"
  fi
  # Bun runtime (nested Mach-O) — sign before the outer app so the seal holds.
  if [ -f "${HELPERS_DIR}/bun" ]; then
    codesign --force --timestamp=none --sign "${IDENTITY}" \
      "${HELPERS_DIR}/bun"
  fi
  # uv runtime (nested Mach-O) — same inside-out signing as bun.
  if [ -f "${HELPERS_DIR}/uv" ]; then
    codesign --force --timestamp=none --sign "${IDENTITY}" \
      "${HELPERS_DIR}/uv"
  fi
  echo "→ codesign appex (${IDENTITY})"
  codesign --force --timestamp=none --sign "${IDENTITY}" \
    --entitlements "${EXT_ENTITLEMENTS}" \
    "${APPEX}"
  echo "→ codesign app (${IDENTITY})"
  codesign --force --timestamp=none --sign "${IDENTITY}" \
    --entitlements "${APP_ENTITLEMENTS}" \
    "${APP_BUNDLE}"
  echo "✓ built + signed ${APP_BUNDLE} (real identity, File Provider enabled)"
else
  echo "→ ad-hoc codesign (File Provider extension will NOT load)"
  codesign --force --sign - "${HELPERS_DIR}/${CTL_NAME}"
  if [ -f "${HELPERS_DIR}/${PDF2MD_NAME}" ]; then
    codesign --force --sign - "${HELPERS_DIR}/${PDF2MD_NAME}"
  fi
  if [ -f "${HELPERS_DIR}/${DEFUDDLE_NAME}" ]; then
    codesign --force --sign - "${HELPERS_DIR}/${DEFUDDLE_NAME}"
  fi
  if [ -f "${HELPERS_DIR}/${PODCAST_HELPER_NAME}" ]; then
    codesign --force --sign - "${HELPERS_DIR}/${PODCAST_HELPER_NAME}"
  fi
  if [ -f "${HELPERS_DIR}/uv" ]; then
    codesign --force --sign - "${HELPERS_DIR}/uv"
  fi
  codesign --force --sign - "${APPEX}"
  codesign --force --sign - "${APP_BUNDLE}"
  echo "✓ built ${APP_BUNDLE} (${CONFIG}, v${VERSION} (${BUILD_VERSION}), ad-hoc)"
fi
