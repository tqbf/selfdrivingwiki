// Bundling build script for markdownlint → single IIFE for JavaScriptCore.
//
// Problem: markdownlint 0.41 is ESM and imports Node builtins (node:fs/os/path)
// via a "#node-imports" subpath condition. It ships a browser shim
// (node-imports-browser.mjs) that throws if those APIs are called — fine for us
// since the sync `strings` lint path never touches fs/os/path.
//
// BUT: naively passing --conditions=browser to esbuild also forces OTHER
// packages onto their browser condition, notably decode-named-character-reference
// which then pulls in a DOM version (document.createElement) that JavaScriptCore
// can't satisfy.
//
// Solution: a targeted onResolve plugin that swaps ONLY "#node-imports" to the
// browser shim, leaving every other package on default conditions (no DOM).
import { build } from "esbuild";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NODE_IMPORTS_SHIM = path.resolve(
  __dirname,
  "node_modules/markdownlint/lib/node-imports-browser.mjs"
);

await build({
  entryPoints: ["entry.mjs"],
  bundle: true,
  format: "iife",
  globalName: "__markdownlint",
  outfile: "../../Resources/markdownlint.bundle.js",
  platform: "neutral",
  logLevel: "info",
  // Target a conservative ES2020 baseline (JavaScriptCore supports it).
  target: "es2020",
  plugins: [
    {
      name: "swap-node-imports",
      setup(build) {
        // Intercept the markdownlint "#node-imports" subpath import and point
        // it at the browser shim (no Node builtins). Everything else resolves
        // normally with no `browser` condition, so DOM-detection packages keep
        // their no-DOM default entry.
        build.onResolve({ filter: /^#node-imports$/ }, () => ({
          path: NODE_IMPORTS_SHIM,
        }));
      },
    },
  ],
});

console.log("✓ markdownlint.bundle.js written");
