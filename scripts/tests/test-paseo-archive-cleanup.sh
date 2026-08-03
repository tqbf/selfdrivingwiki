#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/paseo-archive-cleanup.sh"
FIXTURE="$REPO_ROOT/scripts/tests/paseo-archive-cleanup-fixture.psv"

run_match() {
    local worktree="$1"
    "$SCRIPT" --dry-run --ps-file "$FIXTURE" --worktree "$worktree"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if ! grep -Fq "$needle" <<<"$haystack"; then
        echo "missing expected line: $needle" >&2
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    if grep -Fq "$needle" <<<"$haystack"; then
        echo "unexpected line present: $needle" >&2
        exit 1
    fi
}

alpha_output="$(run_match "/tmp/paseo-worktrees/alpha one")"
beta_output="$(run_match "/tmp/paseo-worktrees/beta[2]")"

assert_contains "$alpha_output" $'MATCH\t101\t1\t101\t'
assert_contains "$alpha_output" $'MATCH\t102\t103\t1002\t'
assert_not_contains "$alpha_output" $'MATCH\t103\t104\t1002\t'
assert_not_contains "$alpha_output" $'MATCH\t104\t200\t1002\t'
assert_not_contains "$alpha_output" $'MATCH\t105\t200\t1002\t'
assert_not_contains "$alpha_output" $'MATCH\t106\t107\t1003\t'
assert_not_contains "$alpha_output" $'MATCH\t107\t200\t1003\t'
assert_not_contains "$alpha_output" $'MATCH\t108\t200\t1003\t'
assert_not_contains "$alpha_output" $'MATCH\t109\t1\t109\t'
assert_not_contains "$alpha_output" $'MATCH\t110\t1\t110\t'

assert_contains "$beta_output" $'MATCH\t106\t107\t1003\t'
assert_not_contains "$beta_output" $'MATCH\t107\t200\t1003\t'
assert_not_contains "$beta_output" $'MATCH\t108\t200\t1003\t'
assert_not_contains "$beta_output" $'MATCH\t101\t1\t101\t'
assert_not_contains "$beta_output" $'MATCH\t102\t103\t1002\t'
assert_not_contains "$beta_output" $'MATCH\t110\t1\t110\t'

echo "paseo-archive-cleanup tests passed"
