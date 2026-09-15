// Builds the vendored Claude ACP adapter bundle: `bun install` from the
// committed lockfile, then `bun build` the adapter's entry point (the
// package's `bin` target, verified via `npm view` at pin time) into a single
// self-contained file that production launches as `<resolved bun> run
// <bundle>` — `bun run <file>` executes the script with its shebang ignored,
// so the adapter itself runs under bun (#1257 Level 2).
//
// Run from this directory: `bun build.mjs` (scripts/sync-acp-adapter.sh does
// exactly that, passing --update-lock only when the pinned version changed).
// Bun embeds input paths as comments in the bundle, so the fixed,
// repo-relative working directory keeps repeated local builds byte-identical
// — the same discipline scripts/sync-extractor-packages.sh uses for the
// Defuddle/Docx2md bundles.
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = path.dirname(fileURLToPath(import.meta.url));
const entry = "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js";
const outfile = "../../Resources/claude-acp-adapter.bundle.js";

// Plain PATH bun first, then the mise-managed one (same fallback order the
// sync script uses).
function bunCommand() {
  for (const argv of [["bun"], ["mise", "exec", "--", "bun"]]) {
    try {
      execFileSync(argv[0], [...argv.slice(1), "--version"], { stdio: "ignore" });
      return argv;
    } catch (err) {
      if (err.code === "ENOENT") continue;
      // A bun that exists but failed to report a version is still a bun —
      // let the real command surface its own failure below.
      return argv;
    }
  }
  console.error(
    "error: bun not found on PATH or via mise — install bun and re-run"
  );
  process.exit(1);
}

const bun = bunCommand();
const updateLock = process.argv.includes("--update-lock");
const installArgs = updateLock ? ["install"] : ["install", "--frozen-lockfile"];
if (!updateLock) {
  console.log(
    "bun install --frozen-lockfile (the committed lockfile must match the pin; " +
      "the sync script passes --update-lock only on a version bump)"
  );
}
execFileSync(bun[0], [...bun.slice(1), ...installArgs], {
  cwd: toolDir,
  stdio: "inherit",
});
execFileSync(
  bun[0],
  [...bun.slice(1), "build", "--target=bun", entry, "--outfile", outfile],
  { cwd: toolDir, stdio: "inherit" }
);
console.log("✓ Resources/claude-acp-adapter.bundle.js written");
