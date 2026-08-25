# Markdown renderer embeds and fenced-code policy

Status: retained design record for PR 2.

> Superseded scope note, 2026-08-19: The static-card and no-PR-3 attachment
> limits in this record apply to the retained PR 2 history. The active inline
> attachment design is in [`dynamic-inline-renderer-attachments.md`](dynamic-inline-renderer-attachments.md).
>
> Superseded role note, 2026-08-25: Syntax now owns the embedding role. Images
> and media stay inline. Approved rich fences use disclosure rows. See
> [`typed-markdown-embed-pipeline.md`](typed-markdown-embed-pipeline.md).

This document records the approved PR 2 contract for typed Markdown embeds,
rich fences, and static renderer cards. It inherits the Phase 1 ordinary code
highlighter but does not widen the reader boundary. Ordinary fenced code stays
escaped and inert. Typed embeds, static cards, and activation are the only new
surface in this phase.

## Contract

The fence policy is closed:

1. Ordinary fences use a neutral `MarkdownFencedBlock` model with typed identity,
   parsed info, and immutable bytes.
2. A `MarkdownBlockID` carries separate typed fields for page identity, exact
   page-version identity, parser-assigned ordinal, and a typed SHA-256 digest of
   the original block bytes plus normalized info string.
3. A closed `MarkdownFencePresentationPolicy` resolves one of three outcomes:
   ordinary inert code with an optional `CodeLanguage`, a host-approved rich
   renderer request, or a raw-code fallback with a typed reason.
4. Host-approved aliases start with `mermaid`, `jsoncanvas`, and `excalidraw`.
   `html`, `scala`, `java`, `swift`, `json`, and unknown fences remain ordinary
   code.
5. A fence label never bypasses content validation. Host approval still requires
   bounded size, MIME or artifact checks, signature or descriptor compatibility,
   and package availability validation.

The typed embedded-content model is also closed:

- `RendererEmbeddedContent` is a tagged type with no mixed raw-ID fields.
- `.source` carries `SourceID`, the exact applicable source or source-Markdown
  version identity, bounded source facts, and immutable authorized bytes.
- `.inlineArtifact` carries `PageID`, exact `PageVersionID`, `MarkdownBlockID`,
  the approved fence kind, and immutable block bytes.
- `WikiRenderContext` builds an immutable renderer-embed projection on the main
  actor and hands it to pure Markdown conversion off-main.
- `RendererEmbedPlan` holds stable placeholder identity, selected exact
  `RendererReference`, input identity, static semantic content, fallback reason,
  and allowed activation modes.
- `RendererAuthorizedInputReader` is backed by a typed immutable payload
  provider and byte-count provider. Closing the provider releases the bytes and
  makes later reads fail with a typed closed or unauthorized error.

## Static cards and fallback

This section records the PR 2 static-card contract. The current inline
attachment contract is in `dynamic-inline-renderer-attachments.md`.

Renderer-backed content renders as a semantic HTML card or placeholder. The
card includes a stable opaque DOM ID, renderer name, content or source label, a
safe summary, a fallback link or code block, an accessible role and name, and
explicit Open or Interact controls.

Static cards remain the fallback surface. Source embeds stay in document flow,
preserve their existing source-link behavior, and keep the exact pinned version.
Inline artifacts stay tied to the exact page version and block identity. A rich
renderer failure preserves the original source link or fenced code and shows a
short reason. It does not hide, rewrite, or discard the underlying Markdown.

JSON Canvas gets a bounded static semantic summary from the typed decoder. It
may show node and edge counts plus a noninteractive preview where practical.
Excalidraw uses a host-generated card rather than executing package JavaScript
in the reader document.

The current Mermaid behavior is preserved during this phase. The new policy may
route it later only after parity tests prove the same DOM class, escaped
`textContent`, theme, and failure behavior.

## Validation and teardown

The bridge path is validated before any session or activation request is built.
`RendererBridgeAuthorizer`, broker bootstrap encoding, descriptor constraints,
API-signature and type-boundary fixtures, input digest checks, MIME checks, and
payload-size checks all stay in this phase.

Teardown is explicit. `dismantleNSView` cancels conversion and embed work,
clears reader-owned handlers, and prepares for attachment teardown. Markdown
conversion and load paths are generation-aware and cancellation-checked before
conversion, after conversion, and before `loadHTMLString`. A dismantled or
stale generation never loads HTML or emits geometry. SwiftUI state is not
written synchronously from `makeNSView`, `updateNSView`, or their delegate
chains.

## Acceptance criteria

- Ordinary fenced code remains escaped and inert.
- Host-approved rich aliases are resolved only by the closed fence policy.
- Typed source and inline-artifact identities never collide and never fall back
  to a raw string sentinel.
- Payload bytes are immutable for the lifetime of the authorized reader.
- Exact version, digest, MIME, and descriptor checks gate every renderer input.
- Static cards preserve a readable fallback path when validation or rendering
  fails.
- Mermaid keeps its current rendered output and raw-code degradation contract.
- JSON Canvas can provide bounded native semantics without provenance writes.
- Excalidraw remains a host-generated card in this phase.
- The reader teardown seam prevents stale conversion, stale geometry, and late
  HTML loads.
- No renderer embed interaction changes source bytes, page bytes, source
  versions, page versions, provenance activity, File Provider projection state,
  or search-index content.
- No PR 3 attachment behavior is introduced here.

This historical limit is superseded for new work. Keep it to describe the PR 2
scope. Use `dynamic-inline-renderer-attachments.md` for the current design.

## Test strategy

- Cover fenced blocks in paragraphs, lists, block quotes, adjacent blocks,
  duplicate identical blocks, edited page versions, malformed info strings,
  unknown languages, oversized blocks, and cancellation.
- Cover hosted reader rendering for static card geometry, headings and quote
  anchors around cards, find, selection and copy, source-link routing,
  dark/light appearance, keyboard activation, and accessibility attributes.
- Reuse the full command-line gate from PR 1 and add focused tests for the new
  typed-embed policy, fallback, teardown, and exact-input validation paths.

## Review and documentation requirements

- Require independent review of SwiftUI, Markdown, accessibility, and
  test-coverage concerns.
- Keep the PR 2 contract indexed from `PLAN.md` and preserve this document as
  the retained design record.
- Record any future design-relevant PR progress in `progress/` when that PR
  lands. Do not collapse this record into implementation notes.

## Risks and boundaries

- Do not start PR 3 attachment work here.
- Do not rewrite the reader into a general SwiftUI Markdown renderer.
- Do not execute package code, build a package session, or add iframe-based
  substitutes in the reader document.
- Do not add chart-specific APIs, writable renderers, network capabilities,
  credentials, workers, or provenance writes.
- Do not weaken the reader sandbox, payload validation, or exact-version pinning.

## Platform and gate policy

Self Driving Wiki supports macOS only. Every phase in this renderer series requires
macOS command-line SwiftPM gates and the required hosted macOS checks. Linux source
portability is an optional, nonblocking diagnostic through `make test-linux`; it is
not a per-PR or release acceptance gate. This is a prospective operator-approved
platform policy change, not a waiver or reclassification of any prior Linux result.
Prior Linux evidence, including EINTR failures, remains evidence of failure and is
not described as a pass. See the dated failure record
[`progress/2026-08-13T000000Z-linux-swift-eintr-failure-record.md`](../progress/2026-08-13T000000Z-linux-swift-eintr-failure-record.md).

The native provenance, closure audit, resource limits, semantic palette,
thread-confinement rule, update process, licenses, and sanitizer limits for
ordinary fenced code remain recorded in
[`markdown-renderer-code-highlighting.md`](markdown-renderer-code-highlighting.md).
