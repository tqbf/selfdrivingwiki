#!/bin/bash
# Safe archive-time cleanup for leaked Swift test processes tied to one Paseo worktree.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp"
TERM_GRACE_SECONDS="${PASEO_ARCHIVE_CLEANUP_TERM_GRACE_SECONDS:-5}"
POLL_INTERVAL_SECONDS="${PASEO_ARCHIVE_CLEANUP_POLL_INTERVAL_SECONDS:-0.2}"
DRY_RUN=0
PS_FILE=""
WORKTREE_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage: scripts/paseo-archive-cleanup.sh [--dry-run] [--ps-file <path>] [--worktree <path>]

Archive cleanup for leaked `swift test` process trees belonging to one Paseo
worktree. Ownership is proven from literal command-line references to that
worktree's `.xctest` bundle or `.build` helper path, then expanded narrowly to
related wrappers in the same process group or ancestor chain.

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

process_snapshot >"$SNAPSHOT_FILE"

awk -F '\t' -v worktree="$WORKTREE_PATH" '
    function argv0_of(cmd, parts) {
        split(cmd, parts, /[[:space:]]+/)
        return parts[1]
    }

    function basename_of(path) {
        sub(/^.*\//, "", path)
        return path
    }

    function references_worktree(cmd) {
        return index(cmd, worktree "/") > 0
    }

    function is_wrapper(cmd, base) {
        base = basename_of(argv0_of(cmd))
        if (base == "swift") return 1
        if (base == "swift-test") return 1
        if (base == "swiftpm-testing-helper") return 1
        if (base == "xctest") return 1
        if (base == "time") return 1
        if (base == "tee") return 1
        if (base == "env") return 1
        return 0
    }

    function is_direct_seed(cmd, base) {
        if (!references_worktree(cmd)) {
            return 0
        }
        if (index(cmd, ".xctest") > 0) {
            return 1
        }

        base = basename_of(argv0_of(cmd))
        if (index(cmd, worktree "/.build/") > 0) {
            if (base == "swiftpm-testing-helper") return 1
            if (base == "xctest") return 1
            if (base == "swift") return 1
            if (base == "swift-test") return 1
        }

        return 0
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

        if (is_direct_seed(cmd)) {
            owned[pid] = 1
            reason[pid] = "direct-test-path"
        }
    }

    END {
        changed = 1
        while (changed) {
            changed = 0

            for (idx = 1; idx <= count; idx += 1) {
                pid = order[idx]
                if (!(pid in owned)) {
                    continue
                }

                parent = ppid_of[pid]
                while (parent != "" && parent != "1") {
                    if (!is_wrapper(cmd_of[parent])) {
                        break
                    }
                    if (!(parent in owned)) {
                        owned[parent] = 1
                        reason[parent] = "ancestor-of-" pid
                        changed = 1
                    }
                    parent = ppid_of[parent]
                }

                pgid = pgid_of[pid]
                for (other_idx = 1; other_idx <= count; other_idx += 1) {
                    other = order[other_idx]
                    if (pgid_of[other] != pgid) {
                        continue
                    }
                    if (!is_wrapper(cmd_of[other])) {
                        continue
                    }
                    if (!(other in owned)) {
                        owned[other] = 1
                        reason[other] = "same-pgid-" pgid
                        changed = 1
                    }
                }
            }
        }

        for (idx = 1; idx <= count; idx += 1) {
            pid = order[idx]
            if (pid in owned) {
                printf "MATCH\t%s\t%s\t%s\t%s\t%s\n", pid, ppid_of[pid], pgid_of[pid], reason[pid], cmd_of[pid]
            }
        }
    }
' "$SNAPSHOT_FILE" >"$MATCHES_FILE"

selected_pids() {
    awk -F '\t' '{ print $2 }' "$MATCHES_FILE"
}

pid_is_alive() {
    local pid="$1"
    if [ -n "$PS_FILE" ]; then
        grep -Fq "$(printf 'MATCH\t%s\t' "$pid")" "$MATCHES_FILE"
    else
        kill -0 "$pid" 2>/dev/null
    fi
}

print_matches() {
    cat "$MATCHES_FILE"
}

signal_pids() {
    local signal_name="$1"
    local pid
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || [ "$pid" = "1" ]; then
            continue
        fi
        if pid_is_alive "$pid"; then
            kill "-$signal_name" "$pid" 2>/dev/null || true
        fi
    done < <(selected_pids)
}

wait_for_exit() {
    local max_polls
    local poll=0
    local pid
    local has_live=0

    max_polls="$(awk -v grace="$TERM_GRACE_SECONDS" -v interval="$POLL_INTERVAL_SECONDS" 'BEGIN {
        value = int((grace / interval) + 0.999)
        if (value < 1) {
            value = 1
        }
        print value
    }')"

    while [ "$poll" -lt "$max_polls" ]; do
        has_live=0
        while IFS= read -r pid; do
            [ -z "$pid" ] && continue
            if pid_is_alive "$pid"; then
                has_live=1
                break
            fi
        done < <(selected_pids)

        if [ "$has_live" -eq 0 ]; then
            return 0
        fi

        sleep "$POLL_INTERVAL_SECONDS"
        poll=$((poll + 1))
    done

    return 1
}

if ! grep -q '^MATCH' "$MATCHES_FILE"; then
    echo "paseo-archive-cleanup: no leaked test processes for $WORKTREE_PATH"
    exit 0
fi

print_matches

if [ "$DRY_RUN" -eq 1 ]; then
    exit 0
fi

signal_pids TERM
if wait_for_exit; then
    exit 0
fi

signal_pids KILL
exit 0
