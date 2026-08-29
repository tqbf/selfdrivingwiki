---
timestamp: 2026-08-28T120000Z
title: PR 1: shared credential service (#1164)
branch: feature/general-credential-service
status: complete
---

# PR 1: shared credential service (#1164)

## Progress

Issue #1159 PR 1, branch `feature/general-credential-service` (base
`73627d9d`, main after the extractor-route stack).

- Domain-neutral credential types in `WikiFSTypes` (`CredentialReference`
  grammar + typed factories, `CredentialInfo` with no value surface,
  redacted `ResolvedCredential`, bounded `CredentialStoreError`,
  `CredentialValue` normalization) and the describe/write/resolve protocol
  split.
- `KeychainSecretStore.readOrThrow` distinguishes absence from Keychain
  failure; `CredentialLocations` maps references onto the EXISTING ACP /
  Extraction / Zotero service-account pairs (no copy, no rename) and
  `org.sockpuppet.WikiFS.credentials` for new references.
- `KeychainCredentialService` + `InMemoryCredentialService`; the three
  legacy stores became thin adapters preserving their public APIs, error
  shapes, and the legacy direct path for provider ids outside the grammar.
- Settings authority: Zotero + Docling token fields are write-only (blank
  start, explicit Save/Remove, configured state via `describe`); Test
  Connection resolves through `HostCredentialActions`; ContentView's Zotero
  presence check uses `describe`.
- Provider env secrets: closed `ProviderSecretEnvironmentVariable` set,
  decode + write-boundary stripping, the app-owned lock-safe migrator
  (write-before-remove, duplicate removal, conflict preservation),
  trusted-host spawn-secret resolution in `AgentProviderRuntime`, env-editor
  rejection, and write-only per-provider credential controls.

## Verification

62 targeted (grammar, contract, parity, migration matrix, scope
  audit, spawn secrets, hosted write-only Settings) + opt-in
  `WIKIFS_KEYCHAIN_TESTS=1` multiprocess fixture. Gates: make lint/build/test
  (3928), git diff --check.
