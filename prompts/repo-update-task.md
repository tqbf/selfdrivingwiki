Update the wiki from this tracked repository.

Wiki state: {{stateFilePath}}
Repository state: {{repoStateFilePath}}
Checkout path: {{checkoutPath}}
Reader digests: {{readerDigestsFilePath}}

Read the repository checkout only. Do not change its files or Git state. Use
the reader digests when available. Revise existing wiki pages for an incremental
pass. Create or revise pages through `wikictl` only. After all required writes
succeed, run `wikictl repo mark-ingested {{repoName}} {{headCommit}}` exactly
once. Do not run that command when the update is incomplete.
