#!/bin/bash
# Safe archive-time cleanup for leaked Swift test processes tied to one Paseo worktree.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp"
DRY_RUN=0
PS_FILE=""
WORKTREE_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage: scripts/paseo-archive-cleanup.sh [--dry-run] [--ps-file <path>] [--worktree <path>]

Archive inspection for leaked `swift test` processes belonging to one Paseo
worktree. It reports direct `.xctest`/`.build` candidates but never signals
them: a `ps` snapshot cannot prove a process lifetime or child handle after a
PID may have been reused.

Options:
  --dry-run         Print matched processes, do not signal anything.
  --ps-file PATH    Read a tab-separated process snapshot fixture instead of `ps`.
                    Format: PID<TAB>PPID<TAB>PGID<TAB>COMMAND
  --worktree PATH   Override the worktree path. Defaults to `PASEO_WORKTREE_PATH`
                    or the current working directory.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --ps-file)
            PS_FILE="${2:-}"
            shift 2
            ;;
        --worktree)
            WORKTREE_OVERRIDE="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "paseo-archive-cleanup: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "$WORKTREE_OVERRIDE" ]; then
    WORKTREE_PATH="$WORKTREE_OVERRIDE"
elif [ -n "${PASEO_WORKTREE_PATH:-}" ]; then
    WORKTREE_PATH="$PASEO_WORKTREE_PATH"
else
    WORKTREE_PATH="$PWD"
fi

canonicalize_path() {
    local raw_path="$1"
    if [ -d "$raw_path" ]; then
        (
            cd "$raw_path" >/dev/null 2>&1 &&
            pwd -P
        ) || printf '%s\n' "$raw_path"
    else
        printf '%s\n' "$raw_path"
    fi
}

WORKTREE_PATH="$(canonicalize_path "$WORKTREE_PATH")"

if [ -z "$WORKTREE_PATH" ]; then
    echo "paseo-archive-cleanup: empty worktree path" >&2
    exit 2
fi

mkdir -p "$TMP_DIR"
SNAPSHOT_FILE="$(mktemp "$TMP_DIR/paseo-archive-cleanup.snapshot.XXXXXX")"
MATCHES_FILE="$(mktemp "$TMP_DIR/paseo-archive-cleanup.matches.XXXXXX")"

cleanup_files() {
    rm -f "$SNAPSHOT_FILE" "$MATCHES_FILE"
}
trap cleanup_files EXIT INT TERM

process_snapshot() {
    if [ -n "$PS_FILE" ]; then
        cat "$PS_FILE"
    else
        ps -axo pid=,ppid=,pgid=,command= | awk '
            {
                pid = $1
                ppid = $2
                pgid = $3
                sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*/, "", $0)
                print pid "\t" ppid "\t" pgid "\t" $0
            }
        '
    fi
}

if ! process_snapshot >"$SNAPSHOT_FILE"; then
    echo "paseo-archive-cleanup: failed to capture process snapshot" >&2
    exit 2
fi

if ! awk -F '\t' -v worktree="$WORKTREE_PATH" '
    function references_worktree(cmd) {
        return index(cmd, worktree "/") > 0
    }

    function is_direct_seed(cmd) {
        if (!references_worktree(cmd)) {
            return 0
        }
        return index(cmd, worktree "/.build/") > 0 && index(cmd, ".xctest") > 0
    }

    {
        pid = $1
        ppid = $2
        pgid = $3
        cmd = $4

        if (pid == "" || pid ~ /^#/) {
            next
        }

        count += 1
        order[count] = pid
        ppid_of[pid] = ppid
        pgid_of[pid] = pgid
        cmd_of[pid] = cmd

        if (pid ~ /^[0-9]+$/ && pid > 1 && is_direct_seed(cmd)) {
            owned[pid] = 1
            reason[pid] = "direct-test-path"
        }
    }

    END {
        for (idx = 1; idx <= count; idx += 1) {
            pid = order[idx]
            if (pid in owned) {
                printf "MATCH\t%s\t%s\t%s\t%s\t%s\n", pid, ppid_of[pid], pgid_of[pid], reason[pid], cmd_of[pid]
            }
        }
    }
' "$SNAPSHOT_FILE" >"$MATCHES_FILE"; then
    echo "paseo-archive-cleanup: failed to classify process snapshot" >&2
    exit 2
fi

print_matches() {
    cat "$MATCHES_FILE"
}

if ! grep -q '^MATCH' "$MATCHES_FILE"; then
    echo "paseo-archive-cleanup: no leaked test processes for $WORKTREE_PATH"
    exit 0
fi

print_matches

if [ "$DRY_RUN" -eq 1 ]; then
    exit 0
fi

echo "paseo-archive-cleanup: refusing to signal snapshot candidates; rerun with --dry-run for inspection" >&2
exit 2
