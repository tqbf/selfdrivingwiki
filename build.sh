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
PDF2MD_NAME="pdf2md"
PDF2MD_SRC="tools/pdf2md/pdf2md"
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
VERSION="${VERSION:-0.0.0-dev}"

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
APP_BIN="${BIN_DIR}/${APP_TARGET_NAME}"
EXT_BIN="${BIN_DIR}/${EXT_NAME}"
CTL_BIN="${BIN_DIR}/${CTL_NAME}"
for b in "${APP_BIN}" "${EXT_BIN}" "${CTL_BIN}"; do
  [ -x "$b" ] || { echo "✗ built binary missing: $b" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Assemble the .app
# ---------------------------------------------------------------------------
echo "→ assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${APPEX_MACOS}" "${HELPERS_DIR}"
cp "${APP_BIN}" "${MACOS_DIR}/${APP_NAME}"
cp "${EXT_BIN}" "${APPEX_MACOS}/${EXT_NAME}"
cp "${CTL_BIN}" "${HELPERS_DIR}/${CTL_NAME}"
# Also drop a copy at build/wikictl for the Phase A gate to invoke directly.
cp "${CTL_BIN}" "${BUILD_DIR}/${CTL_NAME}"
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
# sqlite-vec is now STATICALLY linked (Sources/CSqliteVec, -DSQLITE_CORE) and
# registered per-connection — no runtime dylib to copy.
# Vendored Mermaid 10.9.6 (UMD build) for rendering ```mermaid fenced blocks in
# the reader. Copied as mermaid.js (dropping the `.min`) so the Bundle lookup is
# a simple name=mermaid / ext=js — avoids a flaky double-extension resource
# lookup. A plain JS resource needs no separate codesign step (sealed by the
# outer .app), matching how wiki-identifiers.env is handled.
MERMAID_JS="Resources/mermaid.min.js"
if [ -f "${MERMAID_JS}" ]; then
  cp "${MERMAID_JS}" "${RESOURCES_DIR}/mermaid.js"
else
  echo "  (mermaid.min.js not found at ${MERMAID_JS} — mermaid blocks will render as code)"
fi
# Vendored merval (zero-dependency Mermaid syntax validator), bundled to a single
# self-contained IIFE. Copied as merval.js so the loader's name/ext lookup is
# simple. Runs in a JavaScriptCore JSContext at save time — no Node at runtime.
MERVAL_JS="Resources/merval.bundle.js"
if [ -f "${MERVAL_JS}" ]; then
  cp "${MERVAL_JS}" "${RESOURCES_DIR}/merval.js"
else
  echo "  (merval.bundle.js not found at ${MERVAL_JS} — mermaid save-time validation will be skipped)"
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
	<key>CFBundleVersion</key><string>${VERSION}</string>
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
	<key>CFBundleVersion</key><string>${VERSION}</string>
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
# Identity precedence: SIGN_IDENTITY env (Makefile passes this) → DEV_IDENTITY
# from signing/local.config → ad-hoc ("-").
IDENTITY="${SIGN_IDENTITY:-${DEV_IDENTITY:--}}"
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
  # pdf2md is a plain script bundled in Helpers/ — must also be signed, or the
  # outer app's seal fails ("code object is not signed at all").
  if [ -f "${HELPERS_DIR}/${PDF2MD_NAME}" ]; then
    codesign --force --timestamp=none --sign "${IDENTITY}" \
      "${HELPERS_DIR}/${PDF2MD_NAME}"
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
  codesign --force --sign - "${APPEX}"
  codesign --force --sign - "${APP_BUNDLE}"
  echo "✓ built ${APP_BUNDLE} (${CONFIG}, v${VERSION}, ad-hoc)"
fi
