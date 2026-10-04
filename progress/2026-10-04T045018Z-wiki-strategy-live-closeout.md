---
timestamp: 2026-10-04T045018Z
title: Operator-verified live evaluation closeout for wiki strategies and cumulative ingestion
branch: feature/wiki-strategies-cumulative-ingestion
status: complete
---

# Operator-verified live evaluation closeout for wiki strategies and cumulative ingestion

## Progress

This entry closes out the live evaluation evidence for the feature branch. It
records operator statements and one read-only inspection of the live Flower
wiki. It changes no code and no live data. The inspecting execution was the
zai/glm-5.3 model, authorized by the user.

The operator stated three acceptances. First, the live chat and source
workflow now works in the running app. Second, the real Strategy template
menu workflow works. Third, the operator considers semantic evaluation done
and accepts semantic quality as an operator decision.

Chat fix verification. The beachball record
(`2026-10-04T000154Z-chat-click-beachball-per-frame-writes.md`) left the live
cure unconfirmed and gave the restart to the operator. The external-write
refresh record (`2026-10-03T220708Z-chat-external-write-refresh.md`) left
recovery as an app relaunch. The operator's confirmation of the live
chat and source workflow verifies both fixes in the running app. One item
from those records stays open: the Darwin notification channel root cause
remains unproven. The applied fix does not depend on that channel.

AC4 verification. The operator verified acceptance criterion AC4. The AC
numbering comes from the operator's goal record. This repository's plans
carry the six-item human rubric in
`plans/wiki-strategies-and-cumulative-ingestion.md`, not a numbered AC list.
This entry therefore attributes AC4 to the operator and does not restate its
text as a repository claim.

What this entry does not claim. No `WikiStrategyEvalRunner` live run is
recorded here. The wiki rows below are incidental evidence from a real wiki
the operator built through the app. They are not a named fixture runner
result. No rubric score was machine-assigned. Semantic acceptance is the
operator's decision, per the plan rule that the human rubric is the
authoritative semantic review.

## Evidence

All reads used `sqlite3` with `mode=ro` URIs against
`~/Library/Group Containers/group.com.willsargent.wiki/01M41BV9H7N34EAW18R7G9SQEP.sqlite`.
This task made no live database writes, no paid model calls, and no app
restart or retry.

Strategy row. `wiki_strategy` holds the "Story analysis" template
instructions, 1502 characters, revision 1. The text separates revelation
order from chronology, separates supported facts from labeled
interpretations, requires a citation for each claim, and requires corrected
interpretations to stay in page history. This row is the saved result of the
real template workflow the operator confirmed.

Pages with successive-source provenance and history. `page_versions` joined
to `page_version_sources` shows the primary source advancing across versions
of the same page:

- `01M41R1HH43M9J4YJFRSJ4PXPR` "Eternity, Meaning, and Narrative" — 4
  versions, 6 distinct provenance sources. The first version records primary
  source "000- Eternity - The Flower That Bloomed". Later versions record
  primary "001- Mankind's Shining Future", then "002" through "005" chapter
  sources with supporting roles. The page row shows version 4, a 5,538
  character body, updated 2026-10-03 23:06:22 UTC.
- `01M41RPFTH7FP2HQFG91V8173Q` "Kamrusepa of Tuon" — 3 versions, 5 sources.
- `01M41RPG724ZQAJ6DTB8WBSSC0` "Old Yru Academy of Medicine and Healing" —
  3 versions, 5 sources.
- Four more pages hold 2 versions each: "Utsushikome of Fusai", "The
  Narrator's Other Self", "The Narrator and Ran", "Mankind's Shining Future".

Current citations. `source_links` holds 40 cite rows wiki-wide. The
Eternity page holds 5. Its body uses 13 footnote citations in
`[[source:<id>#"anchor"]]` form. The cited ids span the original chapter
source `01M41BWA5QBRM1CEDX113W5AZJ` and the four chapter sources the live
chat added (`01M41RP20QN06G4YRWGF4PS90D`, `01M41RQ42ZZ59JJMDQ3NJE3NAY`,
`01M41RQFY3QSXTTEKRAK45T254`, recorded in
`2026-10-03T220708Z-chat-external-write-refresh.md`). The body keeps
earlier-source claims, adds later-source positions, and frames the change as
earlier versus new debate.

Strategy-shaped sections. Pages "000: Eternity", "Mankind's Shining Future",
and "The Remaining World and the Grand Alliance" contain both Revelation and
Chronology labels plus interpretation labels. The Eternity page carries
"Interpretive implications" and "Open Questions" sections.

Chat row. `chats` holds one row, `01M41RK6BT9VKFASJEA314EKSQ` ("can you run
extraction for chapters 2 th…"), updated 2026-10-04 02:32:21 UTC.

Totals: 23 pages, 108 sources, 36 page versions, 104 `page_version_sources`
rows, 40 `source_links` rows, 1 chat.

Distinction from prior outcomes. Scripted pipeline tests, harness negative
controls, and the full `make test` suite remain the deterministic gates
recorded in the earlier entries. Known limitations stay as recorded: the
hosted harness is a quiet-CPU guard, not a reproducer of the live loop; the
Darwin notification root cause is unproven; stranded `running` tool-call
items and per-body presentation recompute remain follow-ups. The rows above
add observed live-wiki evidence and operator acceptance on top of those
records. They do not replace them.

## Verification

Verified, as recorded above:

1. Operator statements, taken 2026-10-04: the live chat and source workflow
   works, the real Strategy template menu workflow works, and semantic
   evaluation is done as an operator decision.
2. Read-only inspection (`sqlite3`, `mode=ro`) of the live Flower wiki: the
   strategy row, page versions with successive-source provenance, current
   citations, strategy-shaped sections, the chat row, and the totals.
3. This task ran no live database write, no paid model call, and no restart
   or retry.

Not claimed, unchanged: this entry records no `WikiStrategyEvalRunner` live
run, assigns no rubric score, and treats the wiki rows as incidental
evidence, not a fixture runner result.

This entry shipped without the `## Verification` heading this contract
requires, and the full-suite gate caught it
(`progress/2026-10-04T125722Z-final-gates-red-phase0-blocked.md`). This
section restores the heading and changes no recorded evidence.
