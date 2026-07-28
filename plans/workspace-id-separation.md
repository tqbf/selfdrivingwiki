# Workspace Identifier Boundary

## Goal

Introduce `WorkspaceID` for workspace entities and remove workspace-valued `String` fields from internal Swift APIs.

This change does not alter stored or external identifier text.

## Typed Domain

`WorkspaceID` is a `RawRepresentable`, `Codable`, `Hashable`, and `Sendable` value type in `WikiFSTypes`.

The following APIs use `WorkspaceID`:

- Workspace creation, lookup, abandon, merge, refresh, and conflict store methods.
- Workspace page overlay reads and writes.
- `WorkspaceSummary.id`.
- `WorkspaceRef.workspaceID`.
- `WorkspaceConflict.workspaceID`.
- Workspace values passed through the app ingestion and agent execution layers.

This type separates workspace ULIDs from page, source, chat, queue, and wiki identifiers.

## Compatibility Boundaries

The SQLite schema remains unchanged. The `workspaces.id`, `workspace_refs.workspace_id`, and `workspace_conflicts.workspace_id` columns remain `TEXT` columns.

The GRDB store binds `WorkspaceID.rawValue` to SQL parameters. It constructs `WorkspaceID` immediately after it reads workspace identifier text.

CLI command models continue to store user input as `String`. Commands construct `WorkspaceID` when they call the store. Command output continues to print the raw value.

The `WIKI_WORKSPACE` environment variable remains raw text. The agent launcher converts `WorkspaceID` to `rawValue` only when it creates the environment hint.

This change does not require a schema migration. It does not change CLI syntax, CLI output, environment values, or persisted ULIDs.

## Verification

`WorkspaceIDTests` cover raw-value preservation, primitive-string Codable behavior, identity, equality, and hashing.

The existing workspace test suites cover SQLite round trips, staging, merge, conflicts, refresh, transitions, and CLI routing through the typed store API.
