# Package-declared source types

## Problem

The host once owned Mermaid's MIME knowledge. `MimeType` held
`text/mermaid` and `text/x-mermaid` constants, an `isMermaid` predicate,
and an `.mmd` extension map. Content kind, provenance labels, and ingest
each branched on that data. This broke the extractor rule that package
policy comes from package data, and it could not describe the real
problem: macOS maps `.mmd` to `application/vnd.chipnuts.karaoke-mmd`.

## Design

Manifest revision 6 adds an optional, descriptor-scoped `sourceType`
declaration:

```json
"sourceType": {
  "canonicalMIMEType": "text/vnd.mermaid",
  "mimeAliases": ["text/mermaid", "text/x-mermaid",
                   "application/vnd.chipnuts.karaoke-mmd"],
  "filenameExtensions": ["mmd", "mermaid"]
}
```

Rules:

- Revision 6 is required. A pre-revision-6 declaration fails closed.
- Each MIME value and extension needs an equivalent routing matcher on
  the same descriptor. Recognition and rendering cannot drift.
- Decoding normalizes values and rejects duplicates. Canonical JSON
  emits sorted arrays.
- The declaration is metadata. It grants no new WebKit capability.

The active catalog, `RegisteredRendererSourceTypes`, is a projection of
descriptor declarations. The app derives it from
`RendererPreparation.availableDescriptors` after runtime revalidation
and safe-mode filtering. Headless profiles project the same claims from
the authoritative machine index. Raw, tombstoned, or suppressed records
never contribute.

## Resolution

Resolution takes persisted or declared MIME, the filename extension,
and two bounded byte channels:

- the 4 KiB sniff channel, used by signatures and prefix matchers;
- the 64 KiB artifact channel, used by complete bounded-JSON validators.

One bounded read feeds both channels. Policy:

1. A canonical or alias MIME match that passes every required matcher
   wins over extension evidence.
2. Extension-only resolution applies when the MIME is absent, the
   octet-stream fallback, or the sniffer's generic text verdict. A
   caller-declared MIME is authoritative. It either matches a claim or
   it conflicts, and the extension never overwrites it.
3. A binary signature always wins.
4. Two claims that resolve one input to different canonical values or
   presentation labels fail closed and report ambiguity.
5. Claims with required artifact predicates fail closed without bytes.

## Lifecycle

Renderer packages are optional. Install, removal, safe-mode
suppression, and reset change the catalog only. They never write wiki
databases. Without a claim, a `.mmd` file with no stored MIME ingests
as generic text. An explicit MIME is authoritative: a source whose
mirrors carry the karaoke value keeps it until ingest with an active
claim or an explicit repair run. A generic-text source stays readable,
and the renderer's ordinary matchers still offer its pane when
installed.

## Ingest and presentation

One authoritative promotion site sits in `GRDBWikiStore.addSource`
after detection. A unique claim replaces an inconclusive or aliased
MIME with the canonical value. `ContentKind`, source text
presentation, transclusion, and provenance labels read the same
catalog. Labels use the descriptor display name.

## Explicit repair

`wikictl admin repair-mime` stays dry-run by default. A typed decision
function classifies each candidate row: detector repair, package alias
normalization, canonical no-op, conflict, ambiguity, byteless, or
inconclusive. Candidates are active rows with a NULL mirror or a
mirror that equals a declared claim MIME. Repair updates both active
mirrors, emits one `.source/.updated` event per changed source, and
keeps historical versions. It reads the full 64 KiB artifact channel.
Package absence, ambiguity, and truncated artifacts produce no write.

## Testing

- Portable manifest tests guard revision gating, duplicate
  rejection, matcher drift, and canonical ordering.
- Catalog tests cover alias normalization, conflict preservation,
  ambiguity, and the two byte-channel bounds.
- Store tests cover ingest, repair counters, events, and idempotence.
- A neutrality scan asserts production Swift carries none of the
  Mermaid policy literals.
