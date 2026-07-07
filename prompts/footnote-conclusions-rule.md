FOOTNOTE EVERY CLAIM — When you write a claim, interpretation, or non-obvious fact drawn from a source, footnote it.

FOR WIKI SOURCES — i.e. any file in the wiki's `sources/` directory, not just the files in this ingest batch. Before writing, check whether a source is in the wiki: search `sources.jsonl` or run `wikictl source list --json` and match by filename or display name. If it IS a wiki source, cite it as a `[[source:…]]` wikilink FOLLOWED BY PLAIN TEXT giving a location and the quote: `[^id]: [[source:DisplayName#"distinctive quote from the passage"]] — section 4, "distinctive quote from the passage"`. `DisplayName` is the source's display name from `sources.jsonl` or `wikictl source list`, with no file extension. Example: `[^id]: [[source:Bassham1950#"the dark reactions of photosynthesis"]] — §2, "the dark reactions of photosynthesis"`.

The `#"quote"` INSIDE the link deep-links the passage — it must be wrapped in `#"…"` (the anchor delimiter) to match on re-open. The PLAIN TEXT after the link — a location (section, page, or heading) plus the quoted passage — is what the reader sees, and is what makes each footnote visually DISTINCT. Never write a bare `[[source:DisplayName]]` with no quote and no trailing text: it renders as just the title, so several footnotes to the same source collapse into indistinguishable copies. Always append the location + quote, and when you cite the same source for more than one claim, use a DIFFERENT passage (and its location) each time.

FOR EXTERNAL SOURCES — any paper, book, or URL NOT in the wiki's `sources/`: use `[^id]: Author (Year), "Title", Journal/Publisher. DOI or URL`. Example: `[^id]: Rosenthal (2002), "Explaining Consciousness", in Philosophy of Mind: Classical and Contemporary Readings.`

NO PIPE ALIAS IN A FOOTNOTE. `[[source:X|alias]]` overrides the link's display text — do NOT use it here; put your distinguishing text as PLAIN TEXT after the link instead. `[[source:X#"quote"]]` links a PASSAGE. `#` is the anchor delimiter, `|` is the alias delimiter — never use `|` in a footnote citation.

WRONG — do NOT do any of this: `[^id]: [[Bassham1950 - quote|source:Bassham1950#"quote"]]` `[^id]: [[source:X|Author (Year)]], Journal. Anchor: "quote"` `[^id]: [[source:X]] Author (Year), "Title", Journal.` `[^id]: Author (Year) — Source (path), page N: "quote"`

RIGHT: `[^id]: [[source:DisplayName#"distinctive quote from the passage"]] — section 4, "distinctive quote from the passage"`
