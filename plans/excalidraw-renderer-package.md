---
title: Excalidraw renderer package boundary
status: approved
branch: feature/excalidraw-renderer-package
---

# Excalidraw renderer package boundary

## Decision

Keep `RendererPackages/Excalidraw` as a reviewed local renderer package. Do not copy it into the SwiftPM resource bundle or the signed app. Users install it through Settings → Renderers → Advanced Local Renderer Package Import.

The generic renderer package runtime owns validation, installation, activation, resource serving, safe mode, failure accounting, and Source fallback. The host does not install a package at startup. Startup reads the machine index and publishes the current validated descriptors.

## Matcher migration

Version 1.0.5 declares a bounded generic JSON matcher in `manifest.json`. The matcher requires a complete root JSON object, `type` equal to `excalidraw`, `version` equal to `2`, and an `elements` array whose entries are objects. The matcher does not use executable code, regular expressions, JSONPath, or unbounded traversal.

The host evaluates this typed constraint model for every package. It does not switch on a package format name. JSON Canvas keeps its host-native matching contract through the same bounded constraint evaluator where appropriate.

## Existing installations

Version 1.0.4 machine records contain the serialized `boundedJSONArtifact: excalidraw` matcher. The decode boundary translates that value into the generic constraint model. A private compatibility marker preserves the legacy wire shape when the unchanged record is encoded again. This keeps the original 1.0.4 canonical manifest bytes and package hash valid.

The compatibility path contains no renderer identity, routing, label, bootstrap, or rendering behavior. New manifests encode only the generic matcher. Version 1.0.5 has a new package hash because its manifest bytes changed.

## Reader and WebKit behavior

Markdown fences and source image embeds use the existing descriptor-driven renderer plan. The reader no longer creates host-generated Excalidraw SVG. Installed package content uses the generic renderer attachment and window host. When the package is absent or fails, the reader keeps readable source or image fallback.

The existing renderer package scheme, CSP, isolated WebKit session, input bridge, failure accounting, safe mode, teardown, and Source fallback remain unchanged.

## Verification requirements

- Validate the repository package as version 1.0.5.
- Validate an unchanged version 1.0.4 package and pin its original hash.
- Decode and re-encode the legacy matcher without changing its wire bytes.
- Prove that empty startup reads but does not mutate the machine index.
- Prove that local import and removal use the standard package runtime.
- Prove that reader labels derive from descriptors and fallback remains readable.
- Prove that production Swift contains no active Excalidraw policy branch.
- Inspect the built app and confirm that it contains no Excalidraw package payload.
