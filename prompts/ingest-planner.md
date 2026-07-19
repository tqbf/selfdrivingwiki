PLANNER PHASE — Multi-page ingest. You are the PLANNER. Read the staged source files, decide what pages this wiki should have, and write a plan. Do NOT write any wiki pages in this phase.

## Wiki state snapshot

A snapshot of the current wiki state is at: {{STATE_FILE_PATH}}
Read it FIRST to see what pages already exist. This avoids creating duplicates on re-ingest.

## Source files (in your working directory)

{{SOURCE_FILES}}

## Source IDs (required for wikictl log --source)

{{SOURCE_IDS}}

## Instructions

1. Read the wiki state snapshot at the path above to see existing pages and the current index.

2. Check existing pages: `$WIKICTL page list` — update-in-place rather than creating duplicates on re-ingest.

3. For each source file, inspect its size and structure. Use `wc -l`, `head`, `sed -n 'START,ENDp'`, or `grep` to sample the content without reading the entire file if it is large.

4. DECIDE the page set: what summary/entity/concept pages does this wiki need? Each page is backed by content from ONE source file (the `sourceFile` field). Cross-reference across sources to find connections and avoid duplicate pages. If two sources discuss the same topic, assign the page to the source with the most content on that topic and cross-link from the other executor's pages using [[wiki links]].

5. Write your plan to `plan.json` in your current working directory using this EXACT JSON schema:

```json
{
  "pages": [
    {
      "title": "Page Title",
      "sourceFile": "source-1.md",
      "sourceRanges": "lines 1-80",
      "outline": "1-3 sentence description of what this page covers"
    }
  ],
  "sourceIDs": ["<id1>", "<id2>"]
}
```

### Field rules

- `title`: the wiki page title (clear, specific, stable). Upserting an existing title updates it.
- `sourceFile`: the actual filename in your working directory (e.g. "source-1.md").
- `sourceRanges`: a human-readable description of where in the source file the content for this page is (e.g. "lines 1-80" or "section 'Introduction'" or "entire file").
- `outline`: a 1-3 sentence description of what the page will cover.
- `sourceIDs`: the list of source IDs given above. Copy them verbatim.

IMPORTANT:
- Do NOT write any wiki pages in this phase. No `$WIKICTL page add`.
- Do NOT dispatch sub-agents, background tasks, or async agents.
- Do NOT use sleep or ScheduleWakeup.
- Write ONLY `plan.json` and stop.
