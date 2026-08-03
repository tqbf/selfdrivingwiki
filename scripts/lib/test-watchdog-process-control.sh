#!/bin/bash
# Process-control boundary for test-with-watchdog.sh (#1051).
#
# The rule: a numeric PID is never sufficient authority to signal. This library
# only ever signals a PID that bash still lists as one of THIS shell's running
# jobs.
#
# Why `jobs -pr` is sound proof of identity, and `kill -0` is not:
#
#   `kill -0 $pid` asks "does some process with this number exist?". Between the
#   timeout decision and the signal, the child can exit and the kernel can
#   reissue its PID to an unrelated process. The answer stays "yes" and the
#   signal lands on a stranger.
#
#   `jobs -pr` asks "is this still one of MY un-reaped running children?". The
#   kernel cannot recycle a child's PID until its parent reaps it, so while the
#   PID appears in this shell's job table it unambiguously denotes the process
#   this shell launched. No PID-reuse window exists.
#
# This also replaces the previous `pkill -f "[s]wiftpm-testing-helper.*"` sweep,
# which selected processes by command-line appearance rather than by ownership.
#
# The verification predicates are pure: callers pass in a job-table snapshot,
# so they can be unit-tested without launching or signalling anything. See
# scripts/tests/test-test-with-watchdog-process-control.sh.

watchdog_is_positive_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 1))
}

# Refuses PIDs that are structurally never a valid target: non-numeric, 0/1,
# this shell, or this shell's parent.
watchdog_is_signal_candidate_pid() {
    local pid="$1"
    watchdog_is_positive_pid "$pid" && ((pid != $$)) && ((pid != PPID))
}

# Snapshot of this shell's running (un-reaped) job PIDs, one per line. Must be
# called from the shell that owns the job, not from a subshell that launched it.
watchdog_running_child_pids() {
    jobs -pr
}

# PURE: is `pid` present in the supplied job-table snapshot?
# Exact whole-line match, so PID 42 never satisfies a check for PID 4.
watchdog_is_verified_child() {
    local pid="$1"
    local snapshot="$2"
    local candidate

    watchdog_is_signal_candidate_pid "$pid" || return 1
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" == "$pid" ]] && return 0
    done <<<"$snapshot"
    return 1
}

# Signals `pid` only if the snapshot proves it is still our running child.
# Refuses every other signal name so a caller cannot smuggle in a group signal
# (a negative PID) or a stop signal.
watchdog_signal_verified_child() {
    local signal_name="$1"
    local pid="$2"
    local snapshot="$3"

    case "$signal_name" in
        TERM | KILL) ;;
        *)
            echo "test watchdog: refused unsupported signal $signal_name" >&2
            return 1
            ;;
    esac

    if ! watchdog_is_verified_child "$pid" "$snapshot"; then
        echo "test watchdog: refused $signal_name for PID $pid — not a verified running child of this shell" >&2
        return 1
    fi

    builtin kill "-$signal_name" "$pid" 2>/dev/null
}
