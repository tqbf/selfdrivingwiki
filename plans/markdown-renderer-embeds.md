# Markdown renderer embeds and fenced-code policy

This is the retained design record for the Markdown renderer series. Phase 1 is
limited to ordinary fenced-code highlighting. Later typed embeds, static cards,
native attachments, and renderer-package attachments are intentionally deferred.

## Three-way fence policy

1. The closed ordinary-code set (Java, Scala, HTML/XML, Swift, JSON/JSONC) may
   receive native Tree-sitter spans but remains escaped and inert.
2. Host-approved rich aliases are not selected by the code highlighter. Their
   richer policy and raw-code fallback belong to later phases.
3. Every unknown or unavailable fence is escaped plain code with its original
   language class preserved.

Phase 1 does not create renderer descriptors, resolve source embeds, use
iframes, rewrite the reader document, or attach native views. Those alternatives
would change the reader isolation/lifecycle boundary and require their own
approved implementation phase.

## Platform and gate policy

Self Driving Wiki supports macOS only. Every phase in this renderer series requires
macOS command-line SwiftPM gates and the required hosted macOS checks. Linux source
portability is an optional, nonblocking diagnostic through `make test-linux`; it is
not a per-PR or release acceptance gate. This is a prospective operator-approved
platform policy change, not a waiver or reclassification of any prior Linux result.
Prior Linux evidence, including EINTR failures, remains evidence of failure and is
not described as a pass.

The native provenance, closure audit, resource limits, semantic palette,
thread-confinement rule, update process, licenses, and known sanitizer/toolchain
limits are recorded in
[`markdown-renderer-code-highlighting.md`](markdown-renderer-code-highlighting.md).

