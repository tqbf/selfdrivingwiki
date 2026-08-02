#!/bin/bash
# Process-control boundary for test-with-watchdog.sh. Every signal path must
# re-observe the direct child and its process lifetime immediately before use.

watchdog_is_positive_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 ))
}

watchdog_is_signal_candidate_pid() {
    local pid="$1"
    watchdog_is_positive_pid "$pid" && (( pid != $$ && pid != PPID ))
}

# `ps lstart` is display-second granularity and cannot distinguish every PID
# reuse. This shell helper has no high-precision kernel identity API, so its
# production observer explicitly refuses. Tests override the observer to cover
# the boundary; a future native observer must provide a structured lifetime
# token with enough precision before this path may signal.
watchdog_observe_process() {
    return 1
}

# The main watchdog asks this before it launches a child. Returning false keeps
# its wall-clock contract bounded when no high-precision observer is available.
watchdog_has_precise_identity_observer() {
    return 1
}

watchdog_normalize_identity() {
    local requested_pid="$1"
    local snapshot="$2"
    local observed_pid observed_parent observed_lifetime_token

    watchdog_is_signal_candidate_pid "$requested_pid" || return 1
    [[ "$snapshot" != *$'\n'* ]] || return 1
    read -r observed_pid observed_parent observed_lifetime_token <<< "$snapshot"
    watchdog_is_signal_candidate_pid "$observed_pid" || return 1
    watchdog_is_positive_pid "$observed_parent" || return 1
    [[ "$observed_pid" == "$requested_pid" && "$observed_lifetime_token" =~ ^[[:alnum:]_.:-]+$ ]] || return 1
    printf '%s\t%s\t%s\n' "$observed_pid" "$observed_parent" "$observed_lifetime_token"
}

watchdog_capture_identity() {
    local pid="$1"
    local snapshot

    snapshot="$(watchdog_observe_process "$pid")" || return 1
    watchdog_normalize_identity "$pid" "$snapshot"
}

watchdog_identity_is_direct_child() {
    local identity="$1"
    local process_id parent_process_id lifetime_token

    IFS=$'\t' read -r process_id parent_process_id lifetime_token <<< "$identity"
    watchdog_is_positive_pid "$process_id" || return 1
    watchdog_is_positive_pid "$parent_process_id" || return 1
    [[ "$lifetime_token" =~ ^[[:alnum:]_.:-]+$ && "$parent_process_id" == "$$" ]]
}

watchdog_is_verified_direct_child() {
    local pid="$1"
    local expected_identity="$2"
    local observed_identity

    watchdog_is_signal_candidate_pid "$pid" || return 1
    watchdog_identity_is_direct_child "$expected_identity" || return 1
    observed_identity="$(watchdog_capture_identity "$pid")" || return 1
    [[ "$observed_identity" == "$expected_identity" ]]
}

# Tests replace this function with a recorder. The production function verifies
# identity itself so direct sourceable calls cannot bypass ownership checks.
watchdog_send_signal() {
    local signal_name="$1"
    local pid="$2"
    local expected_identity="$3"

    case "$signal_name" in
        TERM|KILL) ;;
        *) return 1 ;;
    esac
    watchdog_is_verified_direct_child "$pid" "$expected_identity" || return 1
    builtin kill "-$signal_name" "$pid" 2>/dev/null
}

watchdog_signal_verified_child() {
    local signal_name="$1"
    local pid="$2"
    local expected_identity="$3"

    case "$signal_name" in
        TERM|KILL) ;;
        *) echo "test watchdog: refused unsupported signal $signal_name" >&2; return 1 ;;
    esac
    if ! watchdog_send_signal "$signal_name" "$pid" "$expected_identity"; then
        echo "test watchdog: $signal_name failed for verified test child PID $pid" >&2
        return 1
    fi
}
