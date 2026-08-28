#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

APP_NAME="Self Driving Wiki"
BUILT_APP="build/${APP_NAME}.app"
INSTALLED_APP="/Applications/${APP_NAME}.app"
REPORT="${ROOT}/tmp/signed-wikid-extractor-report.json"
APP_EXECUTABLE="${INSTALLED_APP}/Contents/MacOS/${APP_NAME}"
XPC_BUNDLE="${INSTALLED_APP}/Contents/XPCServices/wikid.xpc"
APP_PACKAGE="${INSTALLED_APP}/Contents/Resources/ExtractorPackages/SignedWikiDExtractorFixture"
XPC_PACKAGE="${XPC_BUNDLE}/Contents/Resources/ExtractorPackages/SignedWikiDExtractorFixture"

mkdir -p "${ROOT}/tmp"
rm -f "${REPORT}"

./build.sh
rm -rf "${INSTALLED_APP}"
ditto "${BUILT_APP}" "${INSTALLED_APP}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${INSTALLED_APP}"

codesign --verify --deep --strict "${INSTALLED_APP}"
codesign --verify --strict "${XPC_BUNDLE}"
test -x "${APP_PACKAGE}/bin/extractor-process-fixture"
test -x "${XPC_PACKAGE}/bin/extractor-process-fixture"
diff -qr "${APP_PACKAGE}" "${XPC_PACKAGE}"

WIKIFS_SIGNED_EXTRACTOR_PROBE_REPORT="${REPORT}" "${APP_EXECUTABLE}" >/dev/null 2>&1 &
APP_PID=$!
cleanup() {
  if kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

DEADLINE=$((SECONDS + 60))
while [ ! -f "${REPORT}" ]; do
  if ! kill -0 "${APP_PID}" 2>/dev/null; then
    echo "signed app exited before it wrote the extractor probe report" >&2
    exit 1
  fi
  if [ "${SECONDS}" -ge "${DEADLINE}" ]; then
    echo "signed extractor probe timed out" >&2
    exit 1
  fi
  /bin/sleep 0.1
done

python3 - "${REPORT}" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = [
    "reviewedPackageResolved",
    "operationDirectoryIsPrivate",
    "protocolExchangeSucceeded",
    "processGroupTerminated",
    "fixtureChildTerminated",
]
failed = [name for name in required if report.get(name) is not True]
if report.get("version") != 1 or failed or report.get("diagnostics"):
    raise SystemExit(f"signed extractor probe failed: {report}")
print(json.dumps(report, sort_keys=True))
PY

if kill -0 "${APP_PID}" 2>/dev/null; then
  kill "${APP_PID}"
fi
wait "${APP_PID}" || true
trap - EXIT
echo "signed wikid extractor boundary passed"
