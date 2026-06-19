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

APP_NAME="Self Driving Wiki"
APP_TARGET_NAME="WikiFS"
EXT_NAME="WikiFSFileProvider"
CTL_NAME="wikictl"
PDF2MD_NAME="pdf2md"
PDF2MD_SRC="tools/pdf2md/pdf2md"
BUNDLE_ID="org.sockpuppet.WikiFS"
EXT_BUNDLE_ID="org.sockpuppet.WikiFS.FileProvider"
APP_GROUP="group.org.sockpuppet.wiki"
MIN_MACOS="14.0"

APP_ENTITLEMENTS="WikiFS/WikiFS.entitlements"
EXT_ENTITLEMENTS="WikiFS/WikiFSFileProvider.entitlements"
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
# Bundle the pdf2md PEP 723 script alongside wikictl so PdfExtractionService
# can spawn it at ingest time.
if [ -f "${PDF2MD_SRC}" ]; then
  cp "${PDF2MD_SRC}" "${HELPERS_DIR}/${PDF2MD_NAME}"
  cp "${PDF2MD_SRC}" "${BUILD_DIR}/${PDF2MD_NAME}"
else
  echo "  (pdf2md not found at ${PDF2MD_SRC} — skipping; PDF extraction will fall back to agent Read tool)"
fi
# Copy sqlite-vec dylib for semantic search. Loaded at runtime via
# sqlite3_load_extension when a WikiStore DB is first opened.
VEC_DYLIB="Resources/vec0.dylib"
if [ -f "${VEC_DYLIB}" ]; then
  cp "${VEC_DYLIB}" "${HELPERS_DIR}/"
else
  echo "  (vec0.dylib not found at ${VEC_DYLIB} — semantic search will fall back to LIKE)"
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
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Codesign
# ---------------------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:--}"
if [ "${IDENTITY}" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
  echo "  (identity '${IDENTITY}' not in keychain — falling back to ad-hoc)"
  IDENTITY="-"
fi

REAL_SIGNING=0
if [ "${IDENTITY}" != "-" ] && [ -f "${APP_PROFILE}" ] && [ -f "${EXT_PROFILE}" ]; then
  REAL_SIGNING=1
fi

if [ "${REAL_SIGNING}" = "1" ]; then
  echo "→ embedding provisioning profiles"
  cp "${APP_PROFILE}" "${CONTENTS}/embedded.provisionprofile"
  cp "${EXT_PROFILE}" "${APPEX_CONTENTS}/embedded.provisionprofile"

  # Inside-out: sign nested Mach-O (the wikictl helper + the .appex) first, then
  # the outer app. wikictl needs no entitlements — it's an un-sandboxed helper
  # writing user-owned App Group files, launched by the un-sandboxed app.
  echo "→ codesign wikictl helper (${IDENTITY})"
  codesign --force --timestamp=none --sign "${IDENTITY}" \
    "${HELPERS_DIR}/${CTL_NAME}"
  codesign --force --timestamp=none --sign "${IDENTITY}" \
    "${HELPERS_DIR}/vec0.dylib"
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
  codesign --force --sign - "${HELPERS_DIR}/vec0.dylib"
  if [ -f "${HELPERS_DIR}/${PDF2MD_NAME}" ]; then
    codesign --force --sign - "${HELPERS_DIR}/${PDF2MD_NAME}"
  fi
  codesign --force --sign - "${APPEX}"
  codesign --force --sign - "${APP_BUNDLE}"
  echo "✓ built ${APP_BUNDLE} (${CONFIG}, v${VERSION}, ad-hoc)"
fi
