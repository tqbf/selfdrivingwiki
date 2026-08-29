# Shared credential service (issue #1159)

Status: Implemented (PRs #1164–#1169 stack, one PR per layer).

## Why

Three features each grew their own secret plumbing: `ACPCredentialStore` (agent
providers), `ExtractionCredentialStore` (Anthropic, Gemini, Docling), and
`ZoteroCredentialStore`. Each had its own Keychain service, its own test
double, and its own UI conventions, and two of the Settings surfaces preloaded
the secret into the view. Issue #1159 replaces all of that with one
domain-neutral service and then uses it to hand extractor packages
explicitly authorized, operation-scoped credentials.

## Reference, description, write, resolve

`WikiFSTypes.CredentialTypes.swift` defines the vocabulary every layer shares:

- **`CredentialReference`** — the stable configuration identity: 2–3
  dot-separated labels (`acp.agent-api-key`,
  `provider.claude-acp.anthropic-api-key`). Labels are validated ASCII
  (1–64, alphanumerics plus `_`/`-`, must start and end alphanumeric), so
  dynamic domains can embed existing identifiers verbatim. Typed factories
  (`acpAgent()`, `acpProvider(_:)`, `extraction(_:)`, `zoteroAPIKey()`,
  `providerSecret(providerID:variable:)`) keep call sites from concatenating
  raw strings. There is deliberately no enumeration API — hosts supply the
  references they know about.
- **`CredentialInfo`** — the UI-safe description: configured state, source,
  writability. It has no value field, so Settings and snapshots can consume
  it directly without a leak surface.
- **`ResolvedCredential`** — the privileged value container. Its
  `description`/`debugDescription` are redacted by construction.
- **`CredentialValue`** — the ONE normalization boundary: nil, empty, and
  whitespace-only writes are absence; a real value is preserved byte-for-byte.
- Protocols split the authority: `CredentialDescribing` (UI-safe),
  `CredentialWriting` (write-only), `CredentialResolving` (trusted host
  runtime only).

## Physical locations (compatibility contract)

`CredentialLocations` maps references to Keychain service/account pairs. The
legacy pairs are read and written IN PLACE — the service never copies or
renames an existing item:

| Reference | Service | Account |
| --- | --- | --- |
| `acp.agent-api-key` | `org.sockpuppet.WikiFS.acp` | `acp-agent-api-key` |
| `acp.provider.<id>` | `org.sockpuppet.WikiFS.acp` | `acp-provider:<id>` |
| `extraction.anthropic-api-key` | `org.sockpuppet.WikiFS.extraction` | `anthropic-api-key` |
| `extraction.gemini-api-key` | `org.sockpuppet.WikiFS.extraction` | `gemini-api-key` |
| `extraction.docling-serve-token` | `org.sockpuppet.WikiFS.extraction` | `docling-serve-token` |
| `zotero.api-key` | `org.sockpuppet.WikiFS.zotero` | `zotero-api-key` |
| anything else | `org.sockpuppet.WikiFS.credentials` | the reference itself |

`KeychainSecretStore` remains the only file that calls Security; it gained a
throwing read (`readOrThrow`) that distinguishes absence from Keychain
failure. A provider id outside the credential grammar (exotic custom ids)
keeps the legacy direct path in its adapter, so no stored key is orphaned.

## Process authority

| Surface | Authority |
| --- | --- |
| App (WikiFSApp) | Reads + writes credentials; runs the one-shot provider sidecar migration; owns the extractor authorization writer |
| `wikid` daemon | Reads the same bindings; resolves values independently in its own process; never writes credentials or authorizations |
| Settings views | Hold `CredentialDescribing & CredentialWriting` only — no API can return a value; Test Connection resolves through `HostCredentialActions` outside the view |
| File Provider / `wikictl` | No Keychain access |
| Package processes | Receive only the request-scoped credential file (see below); no resolver, no Keychain API, no parent environment |

## Provider environment secrets

`AgentProvider.env` (persisted in `agent-providers.json`) always had a
no-secret contract; #1159 enforces it:

- `ProviderSecretEnvironmentVariable` is the closed set
  (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`).
- Decode normalization and the `writeAtomically` boundary both strip known
  secret variables, so legacy plaintext cannot resurface and in-memory
  mutations cannot reach the disk.
- `AgentProviderCredentialMigrator` (app launch, inside the sidecar store's
  cross-process lock) scans the RAW file (decode strips the values, so the
  migrator must read the bytes), writes each value to Keychain BEFORE removing
  the sidecar entry, removes exact duplicates, and preserves plaintext on
  conflict (Keychain holds a different value) or write failure. The sidecar is
  rewritten only when every entry resolved.
- The trusted host resolves the selected provider's secrets into its private
  spawn hints (`env.`-prefixed) at preparation time; rotation is visible on
  the next preparation.

## Extractor declarations and authorization

- Manifest revision 2 lets a registration DECLARE requirements
  (`ExtractorCredentialRequirement`: id/kind/optionality/label/purpose).
  Revision 1 decoding rejects the key outright; v1 canonical bytes and
  digests are unchanged.
- `ExtractorCredentialAuthorizationRecord` binds one package lineage + one
  requirement to one `CredentialReference`, pinned to a
  `ExtractorCredentialRequirementFingerprint` over the normalized contract
  (requirement + registration scope). A later revision inherits the grant
  only while the fingerprint is unchanged.
- The store is a secret-free JSON file at
  `<App Group>/credentials/extractor-credential-authorizations.json`:
  read-only reader for app + daemon; app-only writer (role gate, in-process
  gate, flock, atomic replace, 0600). Removal never deletes a record; grants
  never transfer across package IDs.
- `ExtractorCredentialAuthorizationResolver` is pure: admission + exact
  declaration + fingerprint + configured state → `authorized` /
  `unauthorized` / `missingCredential`. Required unsatisfied blocks;
  optional unsatisfied is omitted.

## Operation input (protocol revision 2)

For each execute of a credential-declaring registration, the host:
rechecks admission + catalog membership → reloads authorizations → validates
fingerprints → resolves each authorized reference once → writes
`credentials/<request>/input.json` (created O_EXCL, mode 0400, verified:
regular file, owner, link count 1) inside the private operation root →
launches with a request that carries only the RELATIVE path → deletes the
request subdirectories on EVERY terminal path. Package-controlled strings
(progress, failure frames, mapped errors) pass through
`ExtractorSecretRedactor` first. Revision 1 operations are untouched.

Public non-secret configuration (Docling endpoint + timeout) rides a separate
`ExtractorOperationConfiguration` envelope whose closed field set cannot
represent a secret.

## Prohibited persistence surfaces

Credential VALUES never appear in: manifests, package catalogs, binding
files, `agent-providers.json`, extraction config, wiki databases, queue
payloads, XPC, File Provider, provenance, inspection snapshots, DebugLog, or
retained failures. Authorization records store references (identities), not
values.

## Keychain integration-test limits

CI lacks the production `keychain-access-groups` entitlement, so:

- Automated coverage uses `InMemoryCredentialService` (the contract suite runs
  the same assertions against any conformer), query-shape tests, and the
  location-mapping parity suite.
- `CredentialKeychainMultiprocessTests` (opt-in:
  `WIKIFS_KEYCHAIN_TESTS=1 swift test --filter CredentialKeychainMultiprocessTests`)
  round-trips a unique item through the real service and verifies
  cross-process visibility via the `security` CLI, deleting the item on every
  terminal path.
- The signed app/daemon smoke runbook (plans/keychain-sharing.md §5.2) remains
  the production access-group gate.

## Future consumers

Vimeo transcription, ACP packaging, and generic package settings can adopt the
service by adding reference factories and (where needed) a `CredentialSource`
case — the describe/write/resolve contracts and the no-enumeration rule are
domain-neutral by design.
