// Reviewed docx2md extractor package entry point.
//
// The host writes one JSON request on standard input and closes it, then
// reads JSON Lines frames from standard output. Standard output carries
// protocol frames ONLY; every other message goes to standard error.
//
// This converts a .docx (Office Open XML Word) file to Markdown in two
// stages: mammoth.convertToHtml maps the document's semantic styles to
// HTML, then Turndown (with the GFM plugin) converts that HTML to
// Markdown. mammoth's own Markdown writer is deprecated upstream; the
// two-stage HTML path is the maintainers' recommended route.
//
// Embedded images are NOT extracted. Each image becomes an
// `![Figure N](figure-N.png)` placeholder, and the result frame carries one
// warning reporting how many images were skipped.
//
// Generated bundle: ExtractorPackages/Docx2md/bin/docx2md-extractor.js
// See tools/docx2md/README.md for the update procedure.

import { open, readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import mammoth from "mammoth";
import TurndownService from "turndown";
import {
  highlightedCodeBlock,
  strikethrough,
  taskListItems,
} from "turndown-plugin-gfm";
import mammothPackage from "mammoth/package.json";

const PROTOCOL_REVISION = 1;
const PROTOCOL_KIND = "docx";
const MAMMOTH_VERSION =
  typeof mammothPackage?.version === "string" ? mammothPackage.version : "unknown";

// Host-side frame validation bounds (ExtractorResultFrame): at most 128
// warnings, each non-empty, at most 1,024 UTF-8 bytes, no NUL. Keeping the
// entry point within these bounds means a warning burst can never invalidate
// an otherwise successful extraction.
const MAXIMUM_WARNING_COUNT = 128;
const MAXIMUM_WARNING_BYTES = 1024;

function emit(kind, payload) {
  process.stdout.write(`${JSON.stringify({ kind, payload })}\n`);
}

function fail(requestID, cause, message) {
  emit("failure", {
    requestID,
    cause,
    message: String(message).slice(0, 4096),
  });
}

function readRequest() {
  return new Promise((resolve, reject) => {
    let text = "";
    process.stdin.setEncoding("utf-8");
    process.stdin.on("data", (chunk) => {
      text += chunk;
    });
    process.stdin.on("end", () => resolve(text));
    process.stdin.on("error", reject);
  });
}

/** One-line, bounded warning text the host frame validator accepts. */
function sanitizedWarning(text) {
  const oneLine = String(text).replace(/[\r\n\0]+/g, " ").trim();
  if (oneLine.length === 0) return undefined;
  let bounded = oneLine;
  while (Buffer.byteLength(bounded, "utf-8") > MAXIMUM_WARNING_BYTES) {
    bounded = bounded.slice(0, Math.floor(bounded.length / 2));
  }
  return bounded;
}

// GFM table conversion, adapted from turndown-plugin-gfm (MIT — see
// README.md). Two documented deltas from upstream:
//
// 1. Header fallback. Upstream only converts a table whose first row is
//    entirely `<th>` and keeps every other table as raw HTML. Word tables
//    frequently carry no header-row markup, and a raw HTML blob is exactly
//    the noise this pipeline exists to remove — so the first row of a
//    header-less table is treated as the header row.
// 2. Cell cleanup. mammoth wraps every table cell's content in `<p>`, which
//    upstream's cell rule renders as newlines inside the pipe row; cell
//    content is collapsed to a single line.

const indexOf = Array.prototype.indexOf;

function docxCell(content, node) {
  const clean = content.replace(/\s*\n\s*/g, " ").trim();
  const index = indexOf.call(node.parentNode.childNodes, node);
  return (index === 0 ? "| " : " ") + clean + " |";
}

function docxIsFirstTbody(element) {
  const previousSibling = element.previousSibling;
  return (
    element.nodeName === "TBODY" &&
    (!previousSibling ||
      (previousSibling.nodeName === "THEAD" &&
        /^\s*$/i.test(previousSibling.textContent)))
  );
}

// A tr is a heading row when it is the first row of the table (or of the
// first tbody) — regardless of whether its cells are `<th>` or `<td>`. This
// is the header fallback; upstream additionally required every cell to be
// `<th>`.
function docxIsHeadingRow(tr) {
  const parentNode = tr.parentNode;
  if (parentNode == null) return false;
  return (
    parentNode.nodeName === "THEAD" ||
    (parentNode.firstChild === tr &&
      (parentNode.nodeName === "TABLE" || docxIsFirstTbody(parentNode)))
  );
}

const docxTableRules = {
  tableCell: {
    filter: ["th", "td"],
    replacement: (content, node) => docxCell(content, node),
  },
  tableRow: {
    filter: "tr",
    replacement: (content, node) => {
      let borderCells = "";
      const alignMap = { left: ":--", right: "--:", center: ":-:" };
      if (docxIsHeadingRow(node)) {
        for (const child of node.childNodes) {
          let border = "---";
          const align = (child.getAttribute("align") ?? "").toLowerCase();
          if (align) border = alignMap[align] ?? border;
          borderCells += docxCell(border, child);
        }
      }
      return `\n${content}${borderCells ? `\n${borderCells}` : ""}`;
    },
  },
  table: {
    filter: (node) =>
      node.nodeName === "TABLE" &&
      node.rows != null &&
      node.rows.length > 0 &&
      docxIsHeadingRow(node.rows[0]),
    replacement: (content) => {
      // Ensure there are no blank lines.
      content = content.replace(/\n{2,}/g, "\n");
      return `\n\n${content}\n\n`;
    },
  },
  tableSection: {
    filter: ["thead", "tbody", "tfoot"],
    replacement: (content) => content,
  },
};

function docxTables(turndownService) {
  for (const key of Object.keys(docxTableRules)) {
    turndownService.addRule(key, docxTableRules[key]);
  }
}

/** ZIP local/empty/spanned magic — the container every .docx must have. */
async function hasZipMagic(path) {
  const handle = await open(path, "r");
  try {
    const { buffer, bytesRead } = await handle.read({
      buffer: Buffer.alloc(4),
      position: 0,
      length: 4,
    });
    if (bytesRead < 4) return false;
    return (
      buffer[0] === 0x50 &&
      buffer[1] === 0x4b &&
      (buffer[2] === 0x03 || buffer[2] === 0x05 || buffer[2] === 0x07) &&
      (buffer[3] === 0x04 || buffer[3] === 0x06 || buffer[3] === 0x08)
    );
  } finally {
    await handle.close();
  }
}

/**
 * Classify a mammoth conversion throw. A container the ZIP reader cannot
 * open, or a package missing the Word main document part, is an input
 * problem (unsupported-input). Anything else is a conversion problem
 * (extraction-failure).
 */
function isUnsupportedInputError(error) {
  const text = String(error?.message ?? error).toLowerCase();
  return (
    text.includes("end of central directory") ||
    text.includes("zip") ||
    text.includes("corrupt") ||
    text.includes("main document") ||
    text.includes("document.xml") ||
    text.includes("file not found")
  );
}

async function main() {
  let requestText;
  try {
    requestText = await readRequest();
  } catch (error) {
    process.stderr.write(`Error: unable to read request: ${error}\n`);
    process.exit(2);
  }

  let request;
  try {
    request = JSON.parse(requestText);
  } catch {
    // No request ID is known, so no frame can be attributed.
    process.stderr.write("Error: malformed extractor request\n");
    process.exit(2);
  }

  const requestID = request.requestID;
  if (typeof requestID !== "string" || requestID.length === 0) {
    process.stderr.write("Error: extractor request has no request ID\n");
    process.exit(2);
  }

  if (request.protocolRevision !== PROTOCOL_REVISION) {
    fail(requestID, "invalid-request", "unsupported protocol revision");
    return;
  }
  if (request.kind !== PROTOCOL_KIND) {
    fail(requestID, "invalid-request", "this package extracts DOCX only");
    return;
  }
  const inputPath = request.inputPath;
  const outputPath = request.outputPath;
  if (typeof inputPath !== "string" || typeof outputPath !== "string") {
    fail(requestID, "invalid-request", "request has no input or output path");
    return;
  }

  emit("progress", {
    requestID,
    completedUnitCount: 0,
    totalUnitCount: 2,
    message: "reading source",
  });

  try {
    if (!(await hasZipMagic(inputPath))) {
      fail(requestID, "unsupported-input", "input is not a DOCX (OOXML zip) file");
      return;
    }
  } catch {
    // The input path cannot be read at all — the request, not the document,
    // is the problem (mirrors Defuddle's unreadable-input mapping).
    fail(requestID, "invalid-request", `unable to read input`);
    return;
  }

  // Every embedded image collapses to a placeholder reference. The count is
  // reported in the result warnings so the extraction report stays honest
  // about fidelity loss.
  let imageCount = 0;
  const convertImage = mammoth.images.imgElement(function () {
    imageCount += 1;
    return { src: `figure-${imageCount}.png`, alt: `Figure ${imageCount}` };
  });

  let html;
  let messages = [];
  try {
    const result = await mammoth.convertToHtml(
      { path: inputPath },
      { convertImage },
    );
    html = result.value;
    messages = Array.isArray(result.messages) ? result.messages : [];
  } catch (error) {
    if (isUnsupportedInputError(error)) {
      fail(requestID, "unsupported-input", `input is not a readable DOCX: ${error}`);
      return;
    }
    fail(requestID, "extraction-failure", `unable to convert document: ${error}`);
    return;
  }

  const turndown = new TurndownService({
    headingStyle: "atx",
    codeBlockStyle: "fenced",
    bulletListMarker: "-",
  });
  turndown.use([highlightedCodeBlock, strikethrough, docxTables, taskListItems]);

  let markdown;
  try {
    markdown = turndown.turndown(html);
  } catch (error) {
    fail(requestID, "extraction-failure", `unable to convert HTML to Markdown: ${error}`);
    return;
  }

  // Collapse the blank-line runs HTML-to-Markdown conversion tends to leave
  // behind so the stored document reads cleanly.
  const finalMarkdown = `${markdown.replace(/\n{3,}/g, "\n\n").trim()}\n`;
  if (finalMarkdown.trim().length === 0) {
    fail(requestID, "extraction-failure", "no content was extracted");
    return;
  }

  emit("progress", {
    requestID,
    completedUnitCount: 1,
    totalUnitCount: 2,
    message: "writing markdown",
  });

  try {
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, finalMarkdown, "utf-8");
  } catch (error) {
    fail(requestID, "extraction-failure", `unable to write markdown: ${error}`);
    return;
  }

  const warnings = [];
  for (const message of messages) {
    if (warnings.length >= MAXIMUM_WARNING_COUNT) break;
    const text = sanitizedWarning(
      typeof message === "string" ? message : message?.message ?? message,
    );
    if (text !== undefined) warnings.push(text);
  }
  if (imageCount > 0 && warnings.length < MAXIMUM_WARNING_COUNT) {
    warnings.push(`${imageCount} embedded images were not extracted`);
  }

  emit("result", {
    requestID,
    outputPath,
    markdownByteCount: Buffer.byteLength(finalMarkdown, "utf-8"),
    warnings,
    metadata: { toolName: "mammoth", toolVersion: MAMMOTH_VERSION },
  });
}

await main();
