---
timestamp: 2026-10-26T161438Z
title: Signing-time App Group socket-path budget guard
branch: bugfix/diagnose-agent-spawn-path-too-long
status: active
---

# Signing-time App Group socket-path budget guard

## Progress

A second developer's machine hit `SearchSocketError.pathTooLong(limit: 103, actual: 109)` on every agent spawn. The id was the whole story: `APP_GROUP=group.local.fsargent.selfdrivingwiki` (36 bytes) inside `/Users/fsargent/Library/Group Containers/` (41-byte prefix) leaves 103 − 41 − 3 (`/r/`) − 29 (`<24 hex>.sock`) = 30 bytes of budget, and 36 does not fit. The daemon booted fine because the ordinary socket leaf (`wikid-search.sock`) is short; only the per-run endpoint — the longest path the code composes — overflowed, so the failure surfaced at agent spawn, far from its cause. Nothing in the signing path validated the length: `setup.sh` accepted any id, and `preflight.py` checked only that profiles authorized whatever id was configured.

The fix moves the failure to where the id is chosen and to every build after that:

- `signing/preflight.py` gained `app_group_socket_problem` (constants `SOCKET_MAX_PATH_BYTES` = 103, `GROUP_CONTAINER_MIDDLE_BYTES` = 26, `RUN_ENDPOINT_OVERHEAD_BYTES` = 32, mirroring `SearchSocketWire.maxPathBytes` and `DaemonRunRegistrationBroker.endpointPath` over `DaemonRunEndpointName`'s 24-hex token). The budget is computed from `$HOME`, not hardcoded, because home-path length is the machine-dependent term. `run()` hard-fails (exit 1) with the remedy when the configured id does not fit, and the repair path re-checks after `infer_config`, because an id inferred from an existing profile can be the doomed one. This is the single deliberate exception to preflight's never-break-the-build rule — ad-hoc-signing past a config that dooms the runtime would be the bug again. The module docstring and the Makefile contract comments now name the exception.
- `signing/setup.sh` runs the same check right after `APP_GROUP` is derived, before the manual portal step registers the id for the account. Dying here is cheaper than blessing a doomed id in the portal.
- `signing/local.config.example` documents the limit at the `APP_GROUP` key; `plans/signing-preflight.md` gained a section describing the gate and the remedy (create a shorter group in the portal, bind it to the three bundle ids, set it in `local.config`, `make signing-repair`).

Remedy notes for the affected machine live in the branch's PR discussion: a ≤ 30-byte id, a portal create-and-bind, optionally pinning `KEYCHAIN_ACCESS_GROUP` to the old derived value so stored agent credentials survive the App Group change, and copying `wikis.json` + `<ulid>.sqlite` (+ WAL/SHM) if the old container holds wikis.

## Verification

- `python3 tmp/verify-socket-budget-guard.py` (13 checks, all pass): the brother's exact id + home recompose to a 109-byte endpoint path and are rejected with a message naming `pathTooLong` and `make signing-repair`; the budget for `/Users/fsargent` computes to 30; 30-byte ids pass and 31-byte ids fail (boundary exact); this machine's real id passes; empty ids pass; an absurd 121-byte home hits the budget ≤ 0 branch and names the container location; and an end-to-end `run()` call against a temp `local.config` holding the long id returns exit 1 with the remedy printed before any network or provisioning work, while a fitting id passes the gate.
- `python3 -m py_compile signing/preflight.py` and `bash -n signing/setup.sh` clean.
- `python3 signing/preflight.py --status` on this machine: no false positive, normal healthy report, exit 0.
