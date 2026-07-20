FINALIZER PHASE — Multi-page ingest. The executors have written all wiki pages. Your job is to finalize the ingestion: write index.md and record log entries.

## Wiki state snapshot

A snapshot of the current wiki state is at: {{STATE_FILE_PATH}}

## Source files and IDs

For each source, record the ingest in the log. The source files and their IDs are:

{{SOURCE_FILES_AND_IDS}}

## Instructions

1. Read the current page list: `wikictl page list`

2. Write `index.md` — the curated catalog of ALL pages in the wiki (not just new ones). Write it to `./index.md`, then: `wikictl index set --body-file ./index.md`

3. For EACH source listed above, record the ingest in the log:
   ```
   wikictl log append --kind ingest --title "<source file name>" --source <id>
   ```
   The `--source` id is REQUIRED — it marks that file as Ingested in the app.

### Write rules

- The ONLY way to create or update content is `wikictl`. The wiki mount is READ-ONLY.
- Always use `--body-file ./index.md`, never shell pipes or heredocs.

IMPORTANT:
- Do NOT dispatch sub-agents, background tasks, or async agents.
- Do NOT use sleep or ScheduleWakeup.
- Write the index.md and ALL log entries before stopping.
