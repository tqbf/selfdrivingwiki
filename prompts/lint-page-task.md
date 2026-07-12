TASK — Review and fix the page titled "{{pageTitle}}".

Pre-flight already ran before this agent started:
- WikiLink bracket syntax (\]]) auto-corrected if any were present.
- {{linksSection}}

Steps:
1. Read the page: `wikictl page get --title "{{pageTitle}}"`
2. For each broken link listed above: search `wikictl page list` to find the correct target, create the page if it should exist, or remove the link if spurious.
3. Check the page for other issues (stale content, broken external links, factual gaps) and fix what you can.
4. If any changes are needed, rewrite: `wikictl page upsert --title "{{pageTitle}}"`

**CAS discipline:** When rewriting the page, first read its current `head_version_id` via `wikictl page get --title "{{pageTitle}}" --json` (or the stderr line in text mode), then pass `--expect-head <that id>` to `wikictl page upsert`. On exit code 3 (CAS conflict — the page changed since you read it), re-read once, reapply your fix, and retry. If it fails again, report the conflict rather than looping.

5. Record your findings: `wikictl log append --kind lint`
