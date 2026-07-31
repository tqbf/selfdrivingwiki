# Adversarial review — `plans/wiki-app-platform.md`

Review of the Wiki App platform design record. Focus: what can go wrong, gaps,
and conceptual misses. Written against the plan text, the current codebase
state (schema v47, #129 Resource abstraction shipped, `wikid` a sandboxed XPC
service, sandbox = write-whitelist/fail-open), and the OPEN issues (#261,
#390, #593, #799) the plan claims to generalize.

---

## 0. Bottom line

This is the most ambitious document in `plans/`. It describes a
capability-secure plugin runtime (typed capabilities, mediated credentials, a
default-deny worker, an idempotent commit FSM, two registries, a network
broker, structured provenance, package signing) for a project that is
explicitly **local-only, dev-signed, no notarization**. The plan is honest
about its unknowns — almost every load-bearing mechanism is deferred to "a
prototype must validate." That honesty is the document's main strength and
also its central weakness: **the unknowns are the plan.** Strip out the
mechanisms marked "prototype must prove," "later slice," and "open question,"
and what remains is a vocabulary list and a threat table.

The highest-risk conceptual problem is not any single mechanism — it is that
the **same agent that is susceptible to prompt injection from ingested content
is the trusted author of the code packages** the host then executes. The
security model spends 13 controls defending the *runtime* boundary and
none on the *authoring* boundary, which is the easier pivot.

---

## 1. Strategic / scope risks

### 1.1 Opportunity cost and sequencing are unstated
The plan does not position itself against the in-flight work. The chat
redesign (#982) just hit Phase 6; the daemon Phase C shipped; #129 (Resource)
and the graph model are done. There is no statement of *when* this starts,
*what it blocks*, or *what it defers*. For a solo/local project, a 9-slice
platform effort (A–I) with two new registries, a worker, a WebView, a broker,
a commit service, and a product UI is realistically the next **6–12 months**
of the project. The plan never asks whether that is the right marginal
investment versus, e.g., closing #261/#390/#593 with the simple paths those
issues already describe.

### 1.2 It "generalizes" three issues without closing any — by design
§1: "It does not close issues #261, #390, or #593." §24: "generalizes future
work from issue #261." This is a deliberate hedge, but it has a cost: the
plan **prevents the simple solutions from landing on their own terms**. Once a
"platform direction of record" exists:

- **#261** (Slack/Tavily/git/archives as `SourceProvider` cases) is a few
  leaf conformers against an existing protocol. The platform reframes Slack
  as "the first source-producing Wiki App" (§25 Slice H/F) — a far heavier
  path. The plan does not say which wins if someone implements #261 the
  simple way tomorrow.
- **#390** (`wikictl source add`) is OPEN and small. §4/§8 explicitly fork
  the source-registration surface: "a future CLI command and the Wiki App
  host can share a typed internal source-registration service. **Neither
  surface invokes the other.**" Two source-registration codepaths that
  deliberately don't call each other is a divergence seed. Expect the two to
  drift on validation, provenance, and idempotency.
- **#593** (Excalidraw) is OPEN with a self-contained WKWebView proposal
  (issue Option A). The plan promotes it to "renderer-platform validation
  case" and bans "one `SourceDetailView` branch per format." That is scope
  inflation that **blocks a shippable feature behind an unbuilt platform.**

**Recommendation:** decide explicitly, in the doc, whether the platform
*replaces* or *coexists with* the simple paths. "Coexists" is the current
text, and it is the most expensive of the three options to maintain.

### 1.3 "Architecture only" with no committed build
§1: the doc "does not implement a registry, worker, WebView, schema, or user
interface." §26 test suites are all "Future suites include." The realistic
failure mode for a design record with no build is that it **constrains future
work without delivering value**, then rots. Either commit to Slice A as a
near-term PR, or mark the whole doc explicitly non-binding.

---

## 2. The authoring boundary is undefended (the core conceptual miss)

The premise (§1): "A user can ask an in-app agent to create or revise [a Wiki
App] without rebuilding the host." The threat table (§13) defends the
*runtime* (bridge, replay, file access, deps, subprocess, network,
credentials, navigation, bombs, provenance, stale revisions, renderer assets,
cache). **It does not model the agent that writes the package.**

The load-bearing fact, from `sandbox-agent.md` and `sandbox-always-on.md`:
the agent runs with **reads open, network open, exec open** — only writes are
fenced, and it is routinely fed ingested, untrusted content (the whole point
of the wiki). That agent is the trusted author of:

- the JS that runs in a capability-bearing WebView (trust level 3, §10);
- the Python/TS backend run by bundled `uv`/`bun`;
- the manifest that declares capabilities, allowed hosts, and matchers;
- the lockfile whose hash binds the package.

So the trust path is: **untrusted ingested bytes → prompt-injected agent →
trusted package code → host capabilities.** Every runtime control in §13
assumes the package is *already* malicious and contains it; none of them
address that the attacker gets to write the package. The installation review
(§12, §15) is the only thing standing between a compromised agent and code
execution, and it is described as a UI step ("installation review for code,
dependencies, network, credentials, and capabilities"). A user reviewing a
generated `bun.lock` and a matcher declaration is not a meaningful control
against a determined adversary, and is exactly the kind of click-through
gate that gets approved on autopilot.

**This inverts the usual plugin-security story.** VS Code / browser
extensions assume a *publisher* with a signing identity produces the package
and a user consents. Here the producer is the low-trust agent process. The
plan's package-trust section (§14: "distinguishes ... signed third-party
packages," "unsigned package cannot shadow a built-in") assumes a PKI the
**host does not have** — the app is dev-signed, local-only (PLAN.md). There
is no signing authority to bind a publisher to. "Local agent-generated" is
listed as a trust class but inherits no actual structural guarantee beyond
the review dialog.

**Recommendation:** add a threat row for "compromised authoring agent" and
say what structural control covers it. If the answer is "only human review,"
say so, and downgrade the security claims accordingly.

---

## 3. Worker isolation is the whole security model, and it does not exist

§6: "The current `SandboxProfile` cannot secure Wiki Apps ... Wiki Apps
require a separate default-deny worker profile and a dedicated helper or XPC
isolation boundary. **A prototype must validate the final mechanism.**" §13,
§16, §27 all defer direct-network enforcement to the same prototype. This is
not one open question — it is the fulcrum the entire threat table leans on:

| Claim in plan | Depends on | Status |
| --- | --- | --- |
| "Normal execution is offline and locked" (§6) | default-deny worker profile | unbuilt, mechanism undecided |
| "No direct network, native broker" (§13/§16) | worker network enforcement | "prototype must prove the enforcement mechanism" (§16) |
| "Subprocess escape" control (§13) | process groups + full-tree kill | `AsyncProcessRunner` "does not establish descendant process-tree termination" today (§6) |
| "Credential theft" control (§13) | worker never sees token bytes | depends on mediated path being *sufficient* (§7 admits raw access may be needed) |

### 3.1 Conflict with the daemon's existing sandbox posture
`wikid` is **already** an App Sandbox XPC service (`xpc-service-migration.md`),
confined to App Group + keychain + `network.client`, with an **OPEN validation
item**: "the daemon runs the Phase C agent engine, which spawns subprocesses
(`bun`, `claude` CLI, `podcast-token-helper`). Under App Sandbox those inherit
confinement and may need additional exceptions. Verify on a real entitled
signed build." The Wiki App worker (Slice E) needs to be **stricter** than
this (default-deny, no direct network) — but the plan never reconciles the
worker with the daemon that already exists. Options the plan leaves open
(§27: "dedicated XPC worker or another helper process") interact badly with
App Sandbox: a stricter helper under the same profile can't *subtract*
entitlements it inherited, and a separate stricter XPC service is another
provisioning/signing profile the project (dev-signed, local) has to manage.
The signing prerequisite that bit `wikid` (loud warning + un-sandboxed
fallback without `signing/wikid.provisionprofile`) will bite the worker too.

### 3.2 `uv`/`bun` are the wrong shape for "default-deny"
Both runtimes are general-purpose language hosts. The plan's "no `uvx`,
`bunx`, unpinned resolution, install scripts, or undeclared native
extensions" (§6) is a **detection problem**, not a declaration problem.
Python C extensions (`.so`/`.dylib` in site-packages) and bun native addons
are how real libraries ship crypto, ML, and parsers. "Undeclared native
extensions" requires the host to enumerate and reject native code inside a
dependency tree the host did not resolve. The plan provides no mechanism, and
the "separate approval operation" for installs (§6/§14) means **every
non-stdlib library need becomes a heavyweight approval** — which either makes
backends near-useless or trains users to rubber-stamp installs.

---

## 4. WebView / RPC bridge — classic XSS→capability pivot

§5/§10 introduce a third WebView (trust level 3) with JS enabled and a typed
bridge installing capability-derived handlers. WKWebView JS↔native bridges
are the single most reused RCE primitive in macOS apps for a reason: every
unlocked capability is a full-host pivot, and the JS runs content that is
frequently attacker-influenced.

Specific gaps:

- **Renderer content is untrusted by definition.** §21: "A renderer receives
  only its authorized source version and **declared linked targets**." The
  matchers are declarative, but the *declared targets* come from the source
  document being rendered (Excalidraw/JSON Canvas files contain arbitrary
  URLs). Native matcher evaluation is the right instinct, but a malicious
  source declares its own exfil targets; the "authorized document" boundary
  is circular when the document is the attack surface.
- **No DOM-sanitization story.** Excalidraw/JSON Canvas render third-party
  JS bundles. A vendored renderer (like the existing Mermaid UMD, per
  `textual-to-wkwebview.md`) becomes part of the TCB. A single XSS in
  Excalidraw's React component is a capability call. The plan lists "no
  undeclared external scripts or iframes" and CSP but does not address
  vendored-bundle vulnerabilities, which are the realistic vector.
- **Three WebViews, three boundaries.** §5 forbids reusing `ChatWebView` or
  relaxing `HTMLSourceWebView`, and adds `WikiAppWebView`. §21 later says
  "separate process pools or nonpersistent data stores **where the prototype
  supports them**." WKWebView process isolation on macOS is not fully under
  app control; the hedge ("where the prototype supports them") concedes the
  isolation may not hold. Cookie/session bleed between a renderer and an
  operational app sharing a process pool is a known WKWebView hazard.

---

## 5. OAuth split-brain (§7)

§7 splits OAuth across the trust boundary: "A backend can construct an
authorization URL, implement PKCE calculations, and parse provider responses.
The host validates redirect and token endpoints before brokered exchange or
refresh." This is a textbook way to introduce OAuth bugs:

- **PKCE verifier custody across the boundary.** If the untrusted backend
  generates the verifier/challenge and hands only the challenge to native,
  the verifier lives in low-trust memory. If native generates both, the
  backend can't complete the flow it "owns." The plan doesn't say who holds
  the verifier, and that choice is where state/PKCE bugs live.
- **State parameter** is mentioned only as "state validation" owned by
  native, but the backend "constructs an authorization URL" — so state must
  round-trip. CSRF protection that crosses a trust boundary with an
  attacker-influenced URL builder is fragile.
- **"Parse provider responses" in the backend** means the low-trust process
  sees token response shape (expiry, scope, refresh presence) even if
  native redeems the code. That leaks enough to mount token-substitution /
  confusion attacks if the broker trusts backend-parsed metadata.

The mediated-fetch preference (§7, "injects a credential after policy
validation; generated code does not receive token bytes") is the safe path,
and the plan correctly prefers it. But §7 also concedes "raw credential
access is a stronger, short-lived capability" that "should [not] be deferred
unless a required API cannot use mediated requests." In practice, most
non-trivial APIs (Slack pagination with rate-limit headers, streaming,
webhooks) resist pure mediated fetch, which will **pressure the design toward
raw credentials** — exactly the failure mode §7 warns against.

---

## 6. Atomic commit / idempotency FSM (§14, §17) is unspecified where it's hardest

The run FSM (`committing → commit-failed → idempotent recovery`) and "every
mutating request has an idempotency key" is correct in shape but hand-waves
the difficult part: **crash recovery between commit and ack**. §17 lists six
recovery cases (no result / unvalidated / validated / uncommitted / lost ack
/ cancel racing commit) and asserts "a retry returns the prior commit result
or resumes safely." That is exactly-once semantics across crash points — the
classic hard problem — and the plan says only that recovery "checks the
idempotency record." Where is that record stored, and how does it survive a
crash that kills the writer mid-transaction? If the idempotency record is in
the same SQLite DB as the commit, a crash between "write idempotency row" and
"write content" (or vice versa) is unrecoverable without a 2PC-style log;
AGENTS.md is explicit that the store is method-atomic with savepoint nesting
and that **no statement handle may cross a method boundary**. The plan's
"stages all proposed mutations and validates the complete set before a native
transaction" (§17) is compatible with that, but only if the entire
multi-artifact proposal commits in **one** `withTransaction` — which §8 says
requires "a new store-level atomic operation." That operation does not exist,
is a public-contract change (§25 Slice F), and interacts with the
single-threaded WAL invariant (AGENTS.md: never run inference/network inside
a transaction).

**Risk:** the "atomic recovery" headline is the marquee feature and it is the
least-specified part of the doc.

---

## 7. Persistence & migration debt

- **Schema is at v47** (`GRDBWikiStore.swift`). §11 defers "the exact SQL
  shape to a later implementation slice," but the list (apps, versions,
  registrations, grants, policy version, runs, audit events, artifact links,
  app-data with per-app schemas **and migrations**) is realistically 4–6
  migration versions on an already heavy ladder, each a compatibility
  contract (AGENTS.md: raw SQLite/JSON/wiki-link/CLI formats are
  compatibility contracts).
- **"Apps cannot create arbitrary SQLite tables" (§17)** but each app gets "an
  explicit schema version and migration operation" in a namespaced app-data
  service. That is a **plugin-owned schema-migration engine inside the host's
  SQLite** — a new class of migration that the host's migration ladder (which
  today is host-owned and linear) has to orchestrate. A buggy app migration
  could corrupt shared state. No rollback story for app-data migrations is
  given.
- **Provenance overload.** The graph model already shipped a PROV substrate
  (`agents`/`activities`/`refs`/`blobs`/`source_versions`). §11 says
  "overloading current PROV text fields could support a prototype, but it is
  brittle," then proposes *new* structured records instead of extending the
  existing ones. The plan doesn't say how the new app/run/grant tables relate
  to the existing `agents`/`activities` rows — risk of two parallel PROV
  models.

---

## 8. Concurrency & resource governance vs. what exists

- **GenerationGate is per-`WikiSession`** with `laneLimits [.ingest: 1,
  .interactive: 3]` (`WikiSession.swift:279`, mirrored in the daemon). Wiki
  App runs add a **third** concurrency dimension (worker runs + renderer
  sessions + extraction). §20 lists "workers, queue fairness, priority,
  request concurrency, WebView count" as governed by named policies, but
  never reconciles with the existing gate/`QueueEngine`. Does an app
  extraction consume an `ingest` lane? Does a renderer session count against
  `interactive`? Unspecified. Worst case: an app run starves agent
  generation, or an agent generation blocks a foreground renderer.
- **"Extraction concurrency remains separate from agent-generation
  concurrency" (§23)** restates `extraction-vs-ingestion-lock.md`, good — but
  that lock is per-source today; the platform adds cross-app queue fairness
  on top, which is net-new scheduling the current code does not have.

---

## 9. Dependency / lockfile integrity (§3, §6, §19)

- The manifest "binds lockfile hashes," but **who resolves the lockfile?**
  The agent proposes a backend + deps, but the agent's run is offline (no
  install). So either (a) the agent writes a lockfile it cannot verify
  against a real resolution, and the host approves it blind; or (b) the host
  runs resolution during the "separate approval operation." (b) is safer but
  means the host embeds a `uv`/`bun` dependency resolver and a
  reproducibility checker — a large, attackable surface (resolver bugs,
  registry compromise). The plan is silent on which.
- §19 reproducibility classes are honest ("network and model runs do not
  promise byte-for-byte reproduction"), but the cache-key design (input hash
  + registration + package + lock + runtime + options + tool/model version)
  still has the classic **undeclared-input problem** the plan itself flags
  ("the host does not reuse a cache when an undeclared external input can
  affect output"). Detecting undeclared inputs in arbitrary Python/TS is
  undecidable in general; the plan offers no approximation.

---

## 10. The "validation thesis" validates the easy cases

§1/§25: LiteParse, JSON Canvas, Excalidraw "validate the no-rebuild model."
They do not. They validate the **wrapper**:

- **LiteParse** is a Python PDF→Markdown extractor — structurally identical
  to the already-bundled `pdf2md` (same runtime, same offline shape, same
  single artifact). Registering it proves the registry wraps a known shape.
- **Excalidraw / JSON Canvas** are static, read-only JS viewers with
  `network: none` and no writes — the least-capable trust level.

The architecture's load-bearing complexity lives in the **unproven** cases:
Slack (OAuth + paginated network + multi-artifact atomic commit + credentials
+ refresh + rate limits). §25 Slice H lists "Slack or Zotero as the first
source-producing Wiki App" as the *last* validation step — i.e., the model is
declared sound (§24 step 9: "remove closed routing only after migrations and
compatibility tests exist") *before* the hard case is built. If Slack exposes
a flaw in the mediated-credential or atomic-commit design, the closed routing
is already gone.

**Recommendation:** sequence the hard case (a networked, credentialed,
multi-artifact app) **before** deprecating any built-in path, not after.

---

## 11. Internal gaps & inconsistencies

- **§4 vs §8 on `source.propose`.** §4 says a persistent grant can let
  `source.propose` commit immediately ("`committed`, `awaitingReview`, or
  `rejected`"). §8 says multi-source/multi-artifact proposals require "a new
  store-level atomic operation after complete validation." A
  multi-artifact proposal that is *auto-committed* by a grant is the
  highest-risk path and the least-specified.
- **§10 editing contract.** "Editing is a separate `source.proposeRevision`
  capability" with expected-version — but Excalidraw/JSON Canvas validation
  (Slice H) is read-only, so the editing contract ships with **no
  implementation and no test** for the entire first release. An unexercised
  capability contract is a future source of stale-write bugs.
- **No File Provider interaction mentioned at all.** Wiki Apps produce
  sources/content that the File Provider projects. `ISSUES.md` documents a
  ~5s replica-invalidation window and domains that **wedge** under churn. A
  renderer or extractor that depends on freshly-mounted state will hit this,
  and the plan never mentions the File Provider.
- **§22 "credentials never enter wiki storage; grants can remain
  device-specific"** — but the wiki DB is the synced/shared artifact
  (per-DB File Provider domain). If grants are device-specific, a wiki shared
  across machines (or restored from backup) loses its app capability state.
  Backup/sync policy is asserted ("treats ... separately") but the
  cross-device story for "this wiki references an app this machine doesn't
  have grants for" is the fallback-to-Source path — i.e., **silent feature
  loss on restore**, which is a poor UX.
- **§25 Slice E ("Worker and sandbox") is the single largest risk and is one
  of nine equal-looking slices.** The plan presents A–I as a sequence, but E
  is a hard gate for D, F, G, H, I. If the worker prototype fails (see §3),
  slices F–I are blocked and D is a WebView with nothing to call. The plan
  should mark E as a **go/no-go milestone**, not a peer slice.

---

## 12. What the plan gets right (fairness)

- **Identifier discipline (§2).** No bare `String` in Swift; raw strings
  only at boundaries. This matches AGENTS.md modeling rules and is correct.
- **Source registration / extraction / ingestion kept as separate stages
  (§23).** This preserves `#799` and the existing per-source lock semantics,
  and the "each successful stage remains durable and retryable" rule is the
  right correctness property.
- **Capability-fail-closed decoding, run-bound request IDs, idempotency
  keys (§13/§17).** Aspirational but the right vocabulary.
- **Honest hedging.** The repeated "prototype must validate" / "open
  question" framing is more honest than most design docs. The problem is
  quantitative (too much deferred), not qualitative (the instincts are
  sound).
- **"Installation order never selects an extractor or renderer" (§18).**
  Deterministic, preference-driven resolution is correct and avoids a common
  plugin-system footgun.

---

## 13. Recommendations (kill criteria)

1. **Make Slice E (worker) a documented go/no-go spike before any other
   slice touches production routing.** If a default-deny, no-direct-network,
   full-tree-killable `uv`/`bun` worker cannot be proven under the project's
   dev-signing constraints, the platform's security claims collapse and the
   plan should be re-scoped to read-only renderers only.
2. **Add a "compromised authoring agent" threat and name its structural
   control**, or downgrade the security language. Do not let a UI review
   dialog be the only thing between an injected agent and capability-bearing
   code.
3. **Resolve the platform-vs-simple-path question for #261/#390/#593 in the
   doc.** Either the platform owns these (and they're blocked on it) or it
   doesn't (and they land standalone). "Generalizes without closing" is the
   worst of both.
4. **Sequence a networked, credentialed, multi-artifact app before
   deprecating any built-in**, not as the last validation step (§24 step 9).
5. **Specify the idempotency-record durability** (where it lives relative to
   the commit transaction) before claiming atomic recovery — this is the
   marquee feature and the least-specified.
6. **Reconcile the worker with the existing sandboxed `wikid` XPC service.**
   Two sandboxes (the daemon's App Sandbox + the worker's default-deny
   profile) under one dev-signed app is a signing/entitlements problem that
   already hurt `wikid`; plan for it.
7. **Commit to Slice A as a near-term PR or mark the doc non-binding.** An
   "architecture-only" record with nine slices and zero committed build will
   rot and will quietly veto simpler feature work.

---

*Written as an adversarial pass. The plan's instincts are mostly sound; the
risk is that the deferred mechanisms are exactly the ones the claims depend
on, and that "generalizes #261/#390/#593" quietly blocks three shippable
features behind an unbuilt runtime.*
