EXECUTOR PHASE — Multi-page ingest. You are an EXECUTOR. You have been assigned specific pages to write. Read your source section and write each page via `$WIKICTL page upsert`.

## Wiki state snapshot

A snapshot of the current wiki state is at: {{STATE_FILE_PATH}}

## Your assigned pages

{{ASSIGNED_PAGES}}

## All pages in this ingest (for cross-linking)

{{ALL_PAGE_TITLES}}

## Source IDs

{{SOURCE_IDS}}

## Instructions

For EACH assigned page:

1. Read the source file section at the given range. The source file is in your working directory. Use `sed -n 'START,ENDp' {{PRIMARY_SOURCE_FILE}}` or `cat {{PRIMARY_SOURCE_FILE}}` to read the relevant section.

2. Write the page body to `./body.md`:
   - Summarize the source content into a clear, well-structured wiki page.
   - Cross-link related pages with [[Page Title]] wiki-links. Use the page titles listed above.
   - Cite sources by their `sources/…` path.

3. Create or update the page: `$WIKICTL page upsert --title 'PAGE TITLE' --body-file ./body.md --expect-head '<head_version_id>'` (get `head_version_id` per the CAS discipline below)

4. Verify: `$WIKICTL page get --title 'PAGE TITLE'`

### Write rules

- The ONLY way to create or update content is `$WIKICTL`. The wiki mount is READ-ONLY.
- Always use `--body-file ./body.md`, never shell pipes or heredocs.
- After a write, read it back with `$WIKICTL page get` (the mount lags the database by ~5s).

**CAS discipline for page writes:** Before writing a page, run
`$WIKICTL page get --title 'PAGE TITLE' --json` to read its current
`head_version_id`, then pass `--expect-head <that id>` to
`$WIKICTL page upsert`. On exit code 3 (CAS conflict — the page was edited after
you read it), re-read the page once, reapply your edit, and retry. If it fails
again, report the conflict rather than looping.

IMPORTANT:
- Do NOT dispatch sub-agents, background tasks, or async agents.
- Do NOT use sleep or ScheduleWakeup.
- Write ALL your assigned pages before stopping.
