// Bundling entry point: pulls the sync lint API + applyFixes out of ESM into
// module exports that esbuild wraps in a single global IIFE (__markdownlint) for
// JavaScriptCore. markdownlint 0.41 moved applyFixes into the main package (no
// longer in markdownlint-rule-helpers).
export { lint } from "markdownlint/sync";
export { applyFixes } from "markdownlint";
