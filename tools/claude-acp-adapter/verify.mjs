// Verifies the committed bundle actually speaks ACP under the exact launch
// shape production uses: spawn `<resolved bun> run <bundle>` and complete an
// ACP `initialize` JSON-RPC handshake (protocol version 1) over stdio. This
// is a build-tool check (run by hand / by the sync flow), not part of
// `swift test` — it catches `bun build` failures like broken dynamic
// `require`s immediately, before a bad bundle is committed.
//
// Run from this directory: `bun verify.mjs`. Requires bun (PATH or mise).
// The adapter answers `initialize` without launching Claude Code, so no
// `claude` executable is needed for this handshake.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(toolDir, "..", "..");
const bundlePath = path.join(repoRoot, "Resources", "claude-acp-adapter.bundle.js");

if (!fs.existsSync(bundlePath)) {
  console.error(`error: bundle not found at ${bundlePath} — run the build first`);
  process.exit(1);
}

function bunCommand() {
  for (const argv of [["bun"], ["mise", "exec", "--", "bun"]]) {
    try {
      execFileSync(argv[0], [...argv.slice(1), "--version"], { stdio: "ignore" });
      return argv;
    } catch (err) {
      if (err.code === "ENOENT") continue;
      return argv;
    }
  }
  console.error("error: bun not found on PATH or via mise — install bun and re-run");
  process.exit(1);
}

const bun = bunCommand();
// Production launches the adapter with the run's scratch directory as cwd;
// a fresh temp dir mirrors that shape (and keeps any incidental writes out
// of the repo).
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "acp-adapter-verify-"));
const child = spawn(bun[0], [...bun.slice(1), "run", bundlePath], {
  cwd: scratch,
  stdio: ["pipe", "pipe", "pipe"],
});

const initializeRequest = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: 1,
    clientCapabilities: {
      fs: { readTextFile: true, writeTextFile: true },
      terminal: true,
    },
    clientInfo: {
      name: "claude-acp-adapter-verify",
      title: "ACP Adapter Bundle Verify",
      version: "0.0.0",
    },
  },
};

let buffer = "";
let stderrTail = [];
let settled = false;

function finish(ok, message) {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  child.kill("SIGTERM");
  if (ok) {
    console.log(`✓ ACP initialize handshake: ${message}`);
    console.log(`  bundle: ${bundlePath}`);
    console.log(`  launch: ${bun.join(" ")} run <bundle> (cwd = fresh temp scratch)`);
    process.exit(0);
  }
  console.error(`✗ ${message}`);
  if (stderrTail.length > 0) {
    console.error("  stderr tail:");
    for (const line of stderrTail.slice(-20)) console.error(`    ${line}`);
  }
  process.exit(1);
}

const timer = setTimeout(
  () => finish(false, "timed out after 20s waiting for the initialize response"),
  20_000
);

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line.length === 0) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      continue; // non-JSON stdout noise — ignore, keep waiting
    }
    if (message.id !== 1) continue;
    if (message.error) {
      finish(false, `initialize returned a JSON-RPC error: ${JSON.stringify(message.error)}`);
    }
    const version = message.result?.protocolVersion;
    if (version === 1 || version === "1") {
      const agent = message.result?.agentInfo?.name ?? "(unnamed agent)";
      finish(true, `protocol version 1 confirmed by ${agent}`);
    }
    finish(
      false,
      `initialize succeeded but protocolVersion is ${JSON.stringify(version)} (expected 1)`
    );
  }
});

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  for (const line of chunk.split("\n")) {
    if (line.length > 0) stderrTail.push(line);
  }
});

child.on("error", (err) => finish(false, `failed to spawn bun: ${err.message}`));
child.on("exit", (code) =>
  finish(false, `adapter exited (code ${code}) before answering initialize`)
);

child.stdin.write(JSON.stringify(initializeRequest) + "\n");
child.stdin.end();
