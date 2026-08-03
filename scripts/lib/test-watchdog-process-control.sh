#!/bin/bash
# Process-control boundary for test-with-watchdog.sh (#1051).
#
# The rule: a numeric PID is never sufficient authority to signal. This library
# only ever signals a PID that bash still lists as one of THIS shell's running
# jobs.
#
# Why signalling goes through a JOBSPEC (%1) and never through a number:
#
#   `kill -0 $pid` asks "does some process with this number exist?". Between the
#   timeout decision and the signal, the child can exit and the kernel can
#   reissue its PID to an unrelated process. The answer stays "yes" and the
#   signal lands on a stranger.
#
#   Checking `jobs -pr` first is better, but it is still check-then-signal: the
#   snapshot proves the PID was an un-reaped job at snapshot time only. Bash can
#   handle SIGCHLD and reap the job between that check and a later
#   `kill "$pid"`, after which the kernel may recycle the number. A separately
#   captured snapshot therefore cannot authorise a numeric signal.
#
#   `builtin kill -TERM %1` closes this. Bash resolves the jobspec against its
#   own job table at the moment of the signal, so the proof and the signal are a
#   single operation and no recyclable number is ever passed. If the job has been
#   reaped, the builtin fails with "no such job" and delivers nothing.
#
# The numeric predicates below remain for the wait loop and for tests, where a
# stale answer is harmless. They must NOT be used to authorise a signal.
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

# Signals one of THIS shell's background jobs, addressed only by jobspec.
#
# There is deliberately no PID parameter and no snapshot parameter: accepting
# either would reintroduce the check-then-signal race described above. Bash
# performs the ownership lookup and the signal together, and fails closed with
# "no such job" if the job has already been reaped.
#
# Refuses every signal name outside TERM/KILL so a caller cannot smuggle in a
# stop signal, and refuses anything that is not a literal jobspec so a numeric
# PID or a negative process-group number can never reach `kill`.
watchdog_signal_job() {
    local signal_name="$1"
    local jobspec="$2"

    case "$signal_name" in
        TERM | KILL) ;;
        *)
            echo "test watchdog: refused unsupported signal $signal_name" >&2
            return 1
            ;;
    esac

    if [[ ! "$jobspec" =~ ^%[0-9]+$ ]]; then
        echo "test watchdog: refused $signal_name for '$jobspec' — not a jobspec" >&2
        return 1
    fi

    if ! builtin kill "-$signal_name" "$jobspec" 2>/dev/null; then
        echo "test watchdog: $signal_name not delivered to $jobspec — no such job (already exited)" >&2
        return 1
    fi
}
