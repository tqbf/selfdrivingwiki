FOOTNOTE EVERY CLAIM — When you write a claim, interpretation, or non-obvious fact drawn from a source, footnote it.

FOR WIKI SOURCES — i.e. any file in the wiki's `sources/` directory, not just the files in this ingest batch. Before writing, check whether a source is in the wiki: search `sources.jsonl` or run `wikictl source list --json` and match by filename or display name. If it IS a wiki source, cite it with `[^id]: [[DisplayName - distinctive quote from the passage|source:DisplayName#"distinctive quote from the passage"]]`. `DisplayName` is the source's display name from `sources.jsonl` or `wikictl source list`. The quote goes AFTER `#"` with NO pipe, NO "Anchor:" text, and NO journal/DOI metadata — the source already has that. Example: `[^id]: [[Bassham1950 - the dark reactions of photosynthesis|source:Bassham1950#"the dark reactions of photosynthesis"]] and [[Calvin Cycle#Regulation]].`

FOR EXTERNAL SOURCES — any paper, book, or URL NOT in the wiki's `sources/`: use `[^id]: Author (Year), "Title", Journal/Publisher. DOI or URL`. Example: `[^id]: Rosenthal (2002), "Explaining Consciousness", in Philosophy of Mind: Classical and Contemporary Readings.`

`#` IS NOT `|`. `[[source:X|alias]]` changes display text. `[[source:X#"quote"]]` links a PASSAGE. Never use `|` in a footnote citation.

WRONG — do NOT do any of this: `[^id]: [[source:X|Author (Year)]], Journal. Anchor: "quote"` `[^id]: [[source:X]] Author (Year), "Title", Journal.` `[^id]: Author (Year) — Source (path), page N: "quote"`

RIGHT: `[^id]: [[DisplayName - distinctive quote from the passage|source:DisplayName#"distinctive quote from the passage"]]`
