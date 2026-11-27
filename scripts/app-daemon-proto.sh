#!/usr/bin/env bash
#
# app-daemon-proto.sh — generation and compatibility checks for the
# language-neutral app–daemon wire contract (Protocol/app-daemon).
#
# Subcommands:
#   tools            install pinned codegen tools into tmp/app-daemon-tools
#                    (verifies every artifact's SHA-256 against
#                    Protocol/app-daemon/tools.lock.json)
#   generate         regenerate the committed Swift bindings in place
#   check            drift + lint + breaking checks (incl. the negative
#                    breaking-edit test) — no writes to committed files
#   update-baseline  regenerate Protocol/app-daemon/baseline/image.binpb
#                    (compatibility review REQUIRED before committing)
#   interop-build    build the Rust interop peer with `cargo build --locked`
#
# Ordinary `swift build` never needs this script: the generated Swift is
# committed. CI runs `tools`, `check`, and `interop-build` before the Swift
# jobs that need them.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$REPO_ROOT/Protocol/app-daemon"
TOOLS_DIR="$REPO_ROOT/tmp/app-daemon-tools"
LOCK="$PROTO_DIR/tools.lock.json"
BASELINE="$PROTO_DIR/baseline/image.binpb"
GENERATED_DIR="$PROTO_DIR/generated/swift"

log() { printf '%s\n' "$*"; }
fail() { printf 'app-daemon-proto: FAIL: %s\n' "$*" >&2; exit 1; }

json_field() {
  # json_field <file> <python-expr over d>
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
keys = sys.argv[2].split(".")
value = d
for key in keys:
    value = value[key]
print(value)
PYEOF
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- tools -------------------------------------------------------------

install_tool() {
  local name="$1" url="$2" digest="$3" binary="$4"
  local downloads="$TOOLS_DIR/downloads"
  mkdir -p "$downloads"
  local archive="$downloads/$(basename "$url")"
  if [ ! -f "$archive" ]; then
    log "downloading $name"
    curl -sSL -o "$archive" "$url" || fail "download failed: $url"
  fi
  local actual
  actual="$(sha256_of "$archive")"
  if [ "$actual" != "$digest" ]; then
    fail "$name digest mismatch: expected $digest, got $actual"
  fi
  log "verified $name (sha256 ok)"
  echo "$archive"
}

build_from_source() {
  # build_from_source <archive> <product> <binary-name>
  local archive="$1" product="$2" binary="$3"
  local src="$TOOLS_DIR/src/$(basename "$archive" .tar.gz)"
  if [ ! -x "$TOOLS_DIR/bin/$binary" ]; then
    mkdir -p "$TOOLS_DIR/src"
    if [ ! -d "$src" ]; then
      tar xzf "$archive" -C "$TOOLS_DIR/src"
    fi
    log "building $binary from pinned source (this takes a minute)"
    (cd "$src" && swift build -c release --product "$product") \
      || fail "swift build failed for $product"
    cp "$src/.build/release/$product" "$TOOLS_DIR/bin/$binary" \
      || fail "missing build output for $product"
  fi
}

cmd_tools() {
  mkdir -p "$TOOLS_DIR/bin"
  local platform="macos_aarch64"
  [ "$(uname -m)" = "x86_64" ] && platform="macos_x86_64"

  local protoc_url protoc_digest buf_url buf_digest
  protoc_url="$(json_field "$LOCK" platforms.$platform.protoc.url)"
  protoc_digest="$(json_field "$LOCK" platforms.$platform.protoc.sha256)"
  buf_url="$(json_field "$LOCK" platforms.$platform.buf.url)"
  buf_digest="$(json_field "$LOCK" platforms.$platform.buf.sha256)"

  local protoc_zip buf_tgz
  protoc_zip="$(install_tool protoc "$protoc_url" "$protoc_digest")"
  buf_tgz="$(install_tool buf "$buf_url" "$buf_digest")"

  if [ ! -x "$TOOLS_DIR/bin/protoc" ]; then
    rm -rf "$TOOLS_DIR/protoc-dist"
    unzip -q -o "$protoc_zip" -d "$TOOLS_DIR/protoc-dist"
    cp "$TOOLS_DIR/protoc-dist/bin/protoc" "$TOOLS_DIR/bin/protoc"
  fi
  if [ ! -x "$TOOLS_DIR/bin/buf" ]; then
    local tmpdir="$TOOLS_DIR/.buf-extract"
    rm -rf "$tmpdir"; mkdir -p "$tmpdir"
    tar xzf "$buf_tgz" -C "$tmpdir"
    cp "$tmpdir/bin/buf" "$TOOLS_DIR/bin/buf"
    rm -rf "$tmpdir"
  fi

  local sp_archive gsp_archive
  sp_archive="$(install_tool protoc-gen-swift \
    "$(json_field "$LOCK" platforms.$platform.protoc_gen_swift.url)" \
    "$(json_field "$LOCK" platforms.$platform.protoc_gen_swift.sha256)")"
  gsp_archive="$(install_tool protoc-gen-grpc-swift-2 \
    "$(json_field "$LOCK" platforms.$platform.protoc_gen_grpc_swift_2.url)" \
    "$(json_field "$LOCK" platforms.$platform.protoc_gen_grpc_swift_2.sha256)")"
  build_from_source "$sp_archive" protoc-gen-swift protoc-gen-swift
  build_from_source "$gsp_archive" protoc-gen-grpc-swift-2 protoc-gen-grpc-swift-2

  chmod +x "$TOOLS_DIR/bin"/*
  log "tools ready in $TOOLS_DIR/bin"
}

require_tools() {
  for tool in protoc buf protoc-gen-swift protoc-gen-grpc-swift-2; do
    [ -x "$TOOLS_DIR/bin/$tool" ] || cmd_tools
  done
}

# --- generation --------------------------------------------------------

run_codegen() {
  # run_codegen <output-dir>
  local out="$1"
  mkdir -p "$out"
  (cd "$PROTO_DIR" && "$TOOLS_DIR/protoc-dist/bin/protoc" \
    -I proto -I "$TOOLS_DIR/protoc-dist/include" \
    --plugin=protoc-gen-swift="$TOOLS_DIR/bin/protoc-gen-swift" \
    --plugin=protoc-gen-grpc-swift-2="$TOOLS_DIR/bin/protoc-gen-grpc-swift-2" \
    --swift_opt=Visibility=Public \
    --swift_out="$out" \
    --grpc-swift-2_opt=Visibility=Public \
    --grpc-swift-2_out="$out" \
    proto/wikid/appdaemon/v1/*.proto) \
    || fail "protoc generation failed"
}

cmd_generate() {
  require_tools
  rm -rf "$GENERATED_DIR/wikid"
  run_codegen "$GENERATED_DIR"
  log "generated Swift refreshed in $GENERATED_DIR"
}

# --- checks ------------------------------------------------------------

buf_lint() {
  (cd "$PROTO_DIR" && "$TOOLS_DIR/bin/buf" lint proto) \
    || fail "buf lint failed"
}

buf_breaking_against() {
  # buf_breaking_against <baseline-image-path> — returns nonzero on breaking
  (cd "$PROTO_DIR" && "$TOOLS_DIR/bin/buf" breaking proto --against "$1")
}

cmd_check() {
  require_tools

  log "== drift check (regenerate + compare committed bindings)"
  local scratch="$TOOLS_DIR/check-scratch"
  rm -rf "$scratch"; mkdir -p "$scratch"
  run_codegen "$scratch"
  if ! diff -r "$GENERATED_DIR/wikid" "$scratch/wikid" >/dev/null 2>&1; then
    diff -rq "$GENERATED_DIR/wikid" "$scratch/wikid" | head -20
    fail "generated Swift drifted from the committed bindings; run make generate-app-daemon-proto"
  fi
  rm -rf "$scratch"
  log "drift: none"

  log "== buf lint"
  buf_lint

  log "== breaking check against the committed baseline"
  [ -f "$BASELINE" ] || fail "missing baseline image $BASELINE (run update-baseline after review)"
  if ! buf_breaking_against "$BASELINE"; then
    fail "schema edits break wire compatibility against the accepted baseline"
  fi
  log "breaking check: compatible"

  log "== negative test: a removed field (no reservation) must FAIL the check"
  local negative="$TOOLS_DIR/negative-schema"
  rm -rf "$negative"; mkdir -p "$negative"
  cp -R "$PROTO_DIR/proto/." "$negative/"
  # Remove home_page_id from the registry descriptor WITHOUT reserving the
  # number/name — the canonical breaking edit the check must reject.
  python3 - "$negative/wikid/appdaemon/v1/registry.proto" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace(
    "  // Absent when no home page is set — `optional` gives explicit presence on\n"
    "  // both encoders; never send an empty WikiId sentinel.\n"
    "  optional PageId home_page_id = 5;\n",
    "")
open(path, "w").write(text)
PYEOF
  if (cd "$negative/.." && "$TOOLS_DIR/bin/buf" breaking "$negative" --against "$BASELINE" >/dev/null 2>&1); then
    fail "negative test failed: buf accepted a breaking edit (removed field without reservation)"
  fi
  rm -rf "$negative"
  log "negative test: correctly rejected"

  log "== check-app-daemon-proto: ALL PASSED"
}

cmd_update_baseline() {
  require_tools
  mkdir -p "$(dirname "$BASELINE")"
  (cd "$PROTO_DIR" && "$TOOLS_DIR/bin/buf" build proto -o "$BASELINE") \
    || fail "buf build failed"
  log "baseline image refreshed: $BASELINE"
  log "REQUIREMENT: commit this only after a compatibility review (plans/app-daemon-wire-contract.md)"
}

# --- interop -----------------------------------------------------------

cmd_interop_build() {
  local crate="$REPO_ROOT/tools/app-daemon-interop"
  export PROTOC="$TOOLS_DIR/bin/protoc"
  export PROTOC_INCLUDE="$TOOLS_DIR/protoc-dist/include"
  (cd "$crate" && cargo build --locked) \
    || fail "cargo build --locked failed (run 'cargo update' ONLY with a deliberate crate bump)"
  log "interop peer built: $crate/target/debug/app-daemon-interop"
}

# --- dispatch ----------------------------------------------------------

case "${1:-}" in
  tools) cmd_tools ;;
  generate) cmd_generate ;;
  check) cmd_check ;;
  update-baseline) cmd_update_baseline ;;
  interop-build) cmd_interop_build ;;
  *) fail "unknown subcommand '${1:-}' (expected: tools|generate|check|update-baseline|interop-build)" ;;
esac
