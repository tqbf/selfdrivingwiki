# Dynamic renderer plan split

Date: 2026-08-01

The new `plans/dynamic-renderers.md` document defines a focused renderer
feature set. GitHub issue #1026 tracks the shared renderer registry and static
renderer package work.

The renderer plan excludes worker runtimes, network access, credentials, source
writes, extraction, and agent prompts. It uses Excalidraw issue #593 as the
installed WebView validation case. It uses JSON Canvas issue #594 as the
built-in native validation case.

`plans/wiki-app-platform-v2.md` remains the umbrella design and document index.
It keeps the existing worker, registration, provenance, extraction,
source-workflow, and staged-ingestion sections. A new document map delegates
only the renderer-specific contract to the focused renderer plan.

This change updates design documents only. It does not change product behavior,
schema, or code.
