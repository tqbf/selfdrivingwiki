# Ceiling-kill retry context (#610)

When a queued ingestion turn reaches its hard ceiling, the watchdog records
the still-pending permission continuations before cancelling the ACP session.
The record is `debug/ceiling-kill-context.json` in that run's scratch folder.
It contains the actual ceiling duration, capture time, command summary, request
time, and wait duration.

A manual queue retry uses the same queue-item identifier and creates a new
timestamped sibling run directory. The launcher reads the latest prior context
artifact from that sibling set and appends a compact advisory to the retry's
planner and executor prompts. First attempts and retries without a ceiling-kill
artifact receive no extra prompt text.

The Activity window already receives the terminal `turnFailed` event. The
launcher additionally forwards the context advisory as a transcript event, so
the operator can see why the live pending-permission row disappeared after the
terminal cleanup.

This is diagnostic and retry-resilience plumbing only. Permission policy and
the unattended-operation auto-reject budget remain independent safeguards.
