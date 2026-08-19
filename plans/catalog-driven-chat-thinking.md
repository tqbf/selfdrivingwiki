# Catalog-Driven Chat Thinking

## Purpose

This design makes ACP thinking choices durable and evidence-based. It separates provider routing from the running ACP agent identity.

A `ProviderID` selects configured routing state. An `ACPAgentFingerprint` records the agent name and version from `InitializeResponse.agentInfo`.

## Capability Sources

`ThinkingCapabilityResolver` selects one complete capability in this order:

1. Use an authoritative live ACP `thought_level` select.
2. Use the latest cached ACP `thought_level` observation for the selected model.
3. Use an explicit agent adapter that matches the agent identity and version.
4. Use a bundled local override that matches the identity, version, and model.
5. Use no capability.

A higher source replaces lower sources. The resolver never merges choices from different sources.

The standard extractor matches `category == "thought_level"` first. It accepts the literal option ID only when the category is absent.

The extractor preserves the advertised option ID, choice IDs, labels, order, and current value. It does not replace a nonliteral option ID.

## Agent Adapters

An adapter must declare a stable adapter ID, an exact identity, and a version predicate. Opaque versions match only exact rules.

The Codex adapter is the first nonstandard adapter. It accepts the tested `codex-acp` identity from version `0.1.0` up to version `2.0.0`.

The adapter reads only provider-advertised model IDs. It recognizes a family only when two or more IDs use the final `base[value]` form.

Bracket syntax is not a general discovery rule. An unrelated agent with the same syntax does not get a Thinking control.

A legacy cache without `agentInfo` cannot match the Codex adapter in the current catalog. The shipped immutable ACP catalog has no Codex command entry.

`ACPAgentCommandFingerprint` supports a future trusted fallback. It requires exact ordered arguments and one canonical executable path for both commands.

The fingerprint rejects changed arguments, extra flags, unresolved commands, noncanonical paths, and same basenames at different paths. It excludes labels, environment values, and credentials.

## Local Overrides

The bundled local override registry has a versioned Codable schema. Each entry declares a stable override ID and a normalized capability.

Each entry must match one agent identity, a bounded or exact version rule, and explicit model IDs. Validation rejects duplicate, malformed, overlapping, or unversioned entries.

The current bundled registry is empty. The official ACP Agent Registry remains an installation catalog, not a capability registry.

## Durable Observation

`AgentProvidersConfig` keeps `providerModels` keyed by `ProviderID` for JSON compatibility. It also stores a complete catalog observation for each provider.

A successful observation stores these values:

- The provider ID.
- The optional ACP agent fingerprint.
- The advertised models and current model.
- The normalized standard thinking capability.
- The observation time.

An empty or failed refresh keeps the previous valid observation. Legacy JSON without observations or fingerprints still decodes.

## Chat Persistence

Schema version 51 adds two nullable columns to `chats`:

```sql
configured_thinking_option_id TEXT NULL
effective_thinking_option_id TEXT NULL
```

The configured value stores user intent. The effective value stores the last resolved or confirmed value.

`updateChatModelAndThinkingSelection` writes the provider, model, configured value, and effective value in one transaction. It emits one chat update event.

The resolver keeps configured intent when a source changes. It selects an effective value from the live current value, configured value, source default, or first choice.

An explicit unknown model gets no capability. It does not inherit choices from another cached model.

## Application Mechanisms

A normalized capability declares one mechanism:

- `sessionConfig` stores the exact ACP option ID.
- `modelVariants` maps each value to one exact model ID.

`ResolvedThinkingConfiguration` uses an explicit wire discriminator. Legacy payloads without a discriminator decode only as valid session configuration payloads.

Unknown discriminators, mixed fields, missing fields, and ambiguous payloads fail decoding. A missing thinking configuration remains `nil`.

For session configuration, the runtime uses this order:

1. Start or resume the ACP session.
2. Apply and confirm the selected model.
3. Read the complete post-model configuration.
4. Validate the exact option and value.
5. Apply the value when necessary.
6. Consume the returned complete configuration.
7. Confirm the current value.
8. Persist the confirmed effective value.
9. Submit the first turn.

For model variants, the runtime applies the mapped model through the existing model mechanism. It does not send a separate thinking configuration request.

The runtime reads ACP configuration again after each model change. A newly available standard `thought_level` option becomes authoritative before the first turn.

## UI Policy

Draft, idle, restored, live, and daemon paths consume the same normalized resolution. SwiftUI does not inspect agent names or model ID syntax.

The Thinking control remains a compact native macOS `Menu`. The app hides it when no trusted selectable capability exists.

The menu uses the source labels and the effective value. It includes an accessibility label, value, help text, and configured-fallback message.

Model labels remove only suffixes listed by the selected capability. Unrelated `(beta)`, `[preview]`, and version qualifiers remain.

Startup-only, externally configured, unknown, and unsupported effort settings do not create a selectable control.

## Provider Sidecar Concurrency

`AgentProvidersConfigStore` serializes provider-sidecar mutations with an actor gate and a kernel `flock`. Each mutation reloads the latest file while locked.

A successful mutation increments one monotonic generation and atomically replaces the file. The store releases both locks before it emits local and Darwin signals.

A failed mutation does not replace the file or emit a signal. Production logical writes cannot call the legacy direct writer outside the core bootstrap path.

An app-lifetime observer coalesces local and Darwin signals. It reloads draft, open, restored, idle, and live sessions when the generation changes.

App activation compares the sidecar generation again. This repairs a notification that macOS missed while the app was suspended.

## Failure Behavior

A rejected or unconfirmed session change keeps configured intent and the previous valid effective value. The runtime records the failure through `DebugLog`.

A fingerprint, version, model, or source mismatch falls through to the next trusted source. If no source applies, the resolver returns no capability.

## Compatibility

Old provider JSON with only `providerModels` and `thinkingOptionCatalog` decodes successfully. Cached standard ACP metadata remains usable with an unknown fingerprint.

Old chat rows remain valid under schema version 51. Old runtime session-configuration payloads decode through the strict legacy wire rule.

Read-only stores require the version 51 chat columns before they run chat summary queries. This prevents repeated missing-column failures.
