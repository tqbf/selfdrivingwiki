---
timestamp: 2026-07-03T033329Z
title: "2026-07-02 — Fix app launching in the background + \"access data from other apps\" prompt"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-02 — Fix app launching in the background + "access data from other apps" prompt

## Progress


Both symptoms were one bug. At cold launch the app appeared behind other windows
and popped a recurring **"Self Driving Wiki would like to access data from other
apps"** TCC prompt. Root cause: `FileProviderSpike.warmCaches(root:)` eagerly
listed the File Provider mount top-down via `FileManager.contentsOfDirectory`
during the launch `.task`. The File Provider runs in the sandboxed **extension**
(separate bundle id), so reading the domain's directory data tripped
`kTCCServiceSystemPolicyAppData` (the `FileProviderDomainID` indirect object) on
every cold launch. That pending prompt held the app in the background until
dismissed. See [`plans/fileprovider-schema-migration-and-cache-warming.md`](plans/fileprovider-schema-migration-and-cache-warming.md).

- **Removed `warmCaches`** entirely (`Sources/WikiFS/FileProviderSpike.swift`) and
  its two `Task.detached` call sites in `resolvePath`. All leaf-resolution methods
  (`openSource`, `resolveSourceByNameURL`, `resolvePageByTitleURL`) resolve by
  **identifier** via `getUserVisibleURL` through the daemon, so they never needed
  the parent pre-enumerated — verified: no prompt, app foregrounds,
  `FileProviderSpikeMountPathTests` pass. If a path-*traversal* access ever needs a
  warm cache, reintroduce warming lazily at that user-initiated call site only.
- **App Group entitlement** (`build.sh`) — added
  `com.apple.security.application-groups = [${APP_GROUP}]` to the **app** target's
  entitlements (previously only the extension had it). The app accesses the group
  container at launch; the entitlement makes that legitimate (the app's
  provisioning profile already authorizes the group) and avoids a slow TCC/sandbox
  evaluation at launch. Parameterized via `${APP_GROUP}` per-developer like the
  existing extension entitlement.

## Verification

Historical verification remains in the progress record above.
