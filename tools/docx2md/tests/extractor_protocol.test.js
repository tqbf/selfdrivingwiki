// docx2md extractor package test suite.
//
// Ports the protocol coverage of tools/pdf2md/tests/test_extractor_protocol.py
// to bun test, plus conversion assertions against the committed fixture
// document. The entry point runs as a real subprocess (`bun
// extractor-protocol.js`) exactly the way the host launches it.

import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import JSZip from "jszip";

const HERE = import.meta.dir;
const ENTRY = resolve(HERE, "../extractor-protocol.js");
const FIXTURE = resolve(HERE, "fixtures/fixture.docx");

/** One real subprocess run. stdin is written and closed, like the host does. */
async function runEntry(requestText) {
  const proc = Bun.spawn([process.execPath, ENTRY], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  proc.stdin.write(requestText);
  await proc.stdin.end();
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  const exitCode = await proc.exited;
  return { stdout, stderr, exitCode };
}

function parseFrames(stdout) {
  return stdout
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
}

function buildRequest(overrides = {}, paths = {}) {
  return {
    requestID: crypto.randomUUID(),
    protocolRevision: 1,
    kind: "docx",
    mimeType:
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    originalFilename: "source.docx",
    inputPath: paths.input ?? FIXTURE,
    outputPath: paths.output,
    deadlineMillisecondsSince1970: Date.now() + 60_000,
    ...overrides,
  };
}

function tempWorkspace() {
  const root = mkdtempSync(join(tmpdir(), "docx2md-test-"));
  return {
    root,
    output: join(root, "out", "result.md"),
    cleanup() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

/** A minimal docx-shaped zip with arbitrary part contents. */
async function buildDocx(parts) {
  const zip = new JSZip();
  for (const [name, content] of Object.entries(parts)) {
    zip.file(name, content);
  }
  return Buffer.from(await zip.generateAsync({ type: "nodebuffer" }));
}

const EMPTY_BODY_DOCX = {
  "[Content_Types].xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>`,
  "_rels/.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>`,
  "word/document.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body></w:body>
</w:document>`,
};

describe("docx2md extractor protocol", () => {
  let workspace;

  test("happy path: progress frames, one terminal result frame, output written", async () => {
    workspace = tempWorkspace();
    const request = buildRequest({}, { output: workspace.output });
    const { stdout, stderr, exitCode } = await runEntry(JSON.stringify(request));

    expect(exitCode).toBe(0);
    expect(stderr).toBe("");

    const frames = parseFrames(stdout);
    // Frame-stream purity: every stdout line is a protocol frame with a known kind.
    for (const frame of frames) {
      expect(["progress", "result", "failure"]).toContain(frame.kind);
      expect(frame.payload.requestID).toBe(request.requestID);
    }

    const kinds = frames.map((frame) => frame.kind);
    expect(kinds[0]).toBe("progress");
    expect(kinds.filter((kind) => kind === "progress").length).toBe(2);
    // Exactly one terminal frame, and it is a result.
    const terminal = kinds.filter((kind) => kind !== "progress");
    expect(terminal).toEqual(["result"]);

    const result = frames.at(-1).payload;
    expect(result.outputPath).toBe(workspace.output);

    const written = readFileSync(workspace.output, "utf-8");
    expect(Buffer.byteLength(written, "utf-8")).toBe(result.markdownByteCount);
    expect(written.trim().length).toBeGreaterThan(0);

    expect(result.metadata.toolName).toBe("mammoth");
    expect(result.metadata.toolVersion).toMatch(/^\d+\.\d+/);
    expect(Array.isArray(result.warnings)).toBe(true);
  });

  test("fixture conversion shape: headings, emphasis, lists, table, link, image placeholder", async () => {
    workspace = tempWorkspace();
    const request = buildRequest({}, { output: workspace.output });
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);

    const markdown = readFileSync(workspace.output, "utf-8");

    // ATX headings from the Word Heading 1 / Heading 2 styles.
    expect(markdown).toContain("# Fixture Heading One");
    expect(markdown).toContain("## Lists");
    expect(markdown).toContain("## Table");

    // Bold and italic runs (turndown renders emphasis with underscores).
    expect(markdown).toContain("**bold text**");
    expect(markdown).toContain("_italic text_");

    // Unordered and ordered lists (GFM). The item marker is padded to the
    // content indent, so match the marker and content, not the exact spaces.
    expect(markdown).toMatch(/-\s+first bullet/);
    expect(markdown).toMatch(/-\s+second bullet/);
    expect(markdown).toMatch(/1\.\s+first step/);
    expect(markdown).toMatch(/2\.\s+second step/);

    // GFM pipe table with a separator row.
    expect(markdown).toContain("| Alpha | Beta |");
    expect(markdown).toContain("| --- | --- |");
    expect(markdown).toContain("| 1 | 2 |");

    // Hyperlink (turndown keeps the run's emphasis inside the link text).
    expect(markdown).toMatch(/\[_?project site_?\]\(https:\/\/example\.org\//);

    // Image placeholder + the not-extracted warning.
    expect(markdown).toContain("![Figure 1](figure-1.png)");
    const frames = parseFrames(stdout);
    const result = frames.at(-1).payload;
    expect(
      result.warnings.some((warning) =>
        warning.includes("1 embedded images were not extracted"),
      ),
    ).toBeTrue();
  });

  test("unsupported protocol revision → invalid-request frame, exit 0", async () => {
    workspace = tempWorkspace();
    const request = buildRequest({ protocolRevision: 2 }, { output: workspace.output });
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    expect(frames).toHaveLength(1);
    expect(frames[0].kind).toBe("failure");
    expect(frames[0].payload.cause).toBe("invalid-request");
  });

  test("unsupported kind → invalid-request frame, exit 0", async () => {
    workspace = tempWorkspace();
    const request = buildRequest({ kind: "html" }, { output: workspace.output });
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    expect(frames).toHaveLength(1);
    expect(frames[0].kind).toBe("failure");
    expect(frames[0].payload.cause).toBe("invalid-request");
  });

  test("missing paths → invalid-request frame", async () => {
    workspace = tempWorkspace();
    const request = buildRequest();
    delete request.outputPath;
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    expect(frames).toHaveLength(1);
    expect(frames[0].payload.cause).toBe("invalid-request");
  });

  test("missing input file → invalid-request failure frame, exit 0", async () => {
    workspace = tempWorkspace();
    const request = buildRequest(
      { inputPath: join(workspace.root, "absent.docx") },
      { output: workspace.output },
    );
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    const terminal = frames.filter((frame) => frame.kind !== "progress");
    expect(terminal).toHaveLength(1);
    expect(terminal[0].kind).toBe("failure");
    expect(terminal[0].payload.cause).toBe("invalid-request");
  });

  test("malformed request → nonzero exit, no frame", async () => {
    const { stdout, stderr, exitCode } = await runEntry("this is not json");
    expect(exitCode).not.toBe(0);
    expect(stdout).toBe("");
    expect(stderr.length).toBeGreaterThan(0);
  });

  test("request without requestID → nonzero exit, no frame", async () => {
    const { stdout, exitCode } = await runEntry(
      JSON.stringify({ protocolRevision: 1, kind: "docx" }),
    );
    expect(exitCode).not.toBe(0);
    expect(stdout).toBe("");
  });

  test("plain-text input → unsupported-input frame, exit 0", async () => {
    workspace = tempWorkspace();
    const input = join(workspace.root, "source.txt");
    writeFileSync(input, "definitely not a zip file");
    const request = buildRequest({ inputPath: input }, { output: workspace.output });
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    const terminal = frames.filter((frame) => frame.kind !== "progress");
    expect(terminal).toHaveLength(1);
    expect(terminal[0].kind).toBe("failure");
    expect(terminal[0].payload.cause).toBe("unsupported-input");
  });

  test("zip without a Word main document → unsupported-input frame, exit 0", async () => {
    workspace = tempWorkspace();
    const input = join(workspace.root, "source.docx");
    writeFileSync(input, await buildDocx({ "not-a-word-doc.txt": "hello" }));
    const request = buildRequest({ inputPath: input }, { output: workspace.output });
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    const terminal = frames.filter((frame) => frame.kind !== "progress");
    expect(terminal).toHaveLength(1);
    expect(terminal[0].kind).toBe("failure");
    expect(terminal[0].payload.cause).toBe("unsupported-input");
  });

  test("empty document → extraction-failure frame, no output file, exit 0", async () => {
    workspace = tempWorkspace();
    const input = join(workspace.root, "empty.docx");
    writeFileSync(input, await buildDocx(EMPTY_BODY_DOCX));
    const request = buildRequest({ inputPath: input }, { output: workspace.output });
    const { stdout, exitCode } = await runEntry(JSON.stringify(request));
    expect(exitCode).toBe(0);
    const frames = parseFrames(stdout);
    const terminal = frames.filter((frame) => frame.kind !== "progress");
    expect(terminal).toHaveLength(1);
    expect(terminal[0].kind).toBe("failure");
    expect(terminal[0].payload.cause).toBe("extraction-failure");
    expect(existsSync(workspace.output)).toBeFalse();
  });
});
