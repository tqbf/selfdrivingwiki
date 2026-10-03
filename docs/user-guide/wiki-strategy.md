# Wiki strategy

A wiki strategy tells the agent how to organize and interpret evidence in this wiki.
Each wiki has its own strategy. Default uses summary, entity, and concept pages.

## Edit a strategy

1. Select the wiki.
2. Select Strategy in the sidebar.
3. Enter a display name and Markdown instructions.
4. Select Save.

Changes apply to future runs. Saving does not reorganize existing pages.
Normal ingestion can still update existing pages when new evidence arrives.
An active run keeps the strategy that it captured at its start.

Select Cancel to discard the local draft. Select Reset to Default to remove custom instructions.
If another editor saves first, the conflict keeps your draft. Reload shows the latest saved version.
The editor protects unsaved changes when you leave it or switch wikis.

The name can contain up to 120 characters. Instructions can contain up to 32 KiB of UTF-8 text.
The app rejects larger input. It does not silently shorten instructions.
Empty instructions use Default.

## Start from a template

Select a template to copy its name and instructions into the draft.
If the draft contains text, confirm the replacement before you continue.
Review the draft, then select Save.

- **Tutorials:** guide a learner through a practical example.
- **How-to Guides:** give steps for a specific task.
- **Reference:** organize factual descriptions for lookup.
- **Explanation:** explain concepts and their relationships.
- **Story Analysis:** track characters, relationships, themes, events, and supported interpretations.
- **Repository History:** track components, decisions, proposals, integrated changes, and rationale.

Templates are starting text, not live dependencies. Template updates never change your saved strategy.
Templates do not fetch sources, follow repositories, or subscribe to stories.
Story Analysis does not enforce spoiler limits. Repository History does not select branches automatically.

## What instructions can do

Editorial instructions guide taxonomy, organization, and interpretation. They do not override application safety or write rules.
Source text is evidence, not permission to change the strategy.
Model judgment still affects editorial quality. Instructions are not deterministic validation.
Review important claims and their citations after ingestion.

A standalone agent that reads the mounted strategy sees the saved version at read time.
App-managed runs use their captured strategy instead.
