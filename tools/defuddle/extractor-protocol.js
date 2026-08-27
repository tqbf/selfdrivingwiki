// Reviewed Defuddle extractor package entry point.
//
// The host writes one JSON request on standard input and closes it, then
// reads JSON Lines frames from standard output. Standard output carries
// protocol frames ONLY; every other message goes to standard error.
//
// This calls the Defuddle library directly. It does not run the Defuddle
// command line as a second process.
//
// Generated bundle: ExtractorPackages/Defuddle/bin/defuddle-extractor.js
// See tools/defuddle/README.md for the update procedure.

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { Defuddle } from "defuddle/node";

const PROTOCOL_REVISION = 1;
const PROTOCOL_KIND = "html";

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

/** Absent metadata arrives as "" rather than null, so normalize it away. */
function present(value) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
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
    fail(requestID, "unsupported-input", "this package extracts HTML only");
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

  let html;
  try {
    html = await readFile(inputPath, "utf-8");
  } catch (error) {
    fail(requestID, "invalid-request", `unable to read input: ${error}`);
    return;
  }

  let result;
  try {
    // Defuddle parses the string with the same `parseLinkedomHTML` call the
    // reviewed command line makes. `separateMarkdown` is what that command
    // line requests for JSON output, so `contentMarkdown` stays a distinct
    // field from `content`.
    //
    // Upstream marks string input deprecated for a future major version. When
    // the pinned library is updated, check whether a Document must be built
    // here instead. See tools/defuddle/README.md.
    result = await Defuddle(html, undefined, { separateMarkdown: true });
  } catch (error) {
    fail(requestID, "extraction-failure", `unable to parse HTML: ${error}`);
    return;
  }

  const markdown = result.contentMarkdown || result.content || "";
  // A page with no article body, for example a client-rendered shell, still
  // yields residual markup such as "<body></body>" with a zero word count.
  // The reviewed command line reports that page as a failure, and the host
  // then falls back to its built-in tag-based extraction. Treat a zero word
  // count as the same "no article body" signal so the fallback is preserved.
  const hasNoWords = result.wordCount === 0;
  if (markdown.trim().length === 0 || hasNoWords) {
    fail(requestID, "extraction-failure", "no article content was extracted");
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
    await writeFile(outputPath, markdown, "utf-8");
  } catch (error) {
    fail(requestID, "extraction-failure", `unable to write markdown: ${error}`);
    return;
  }

  const articleMetadata = {};
  const title = present(result.title);
  const author = present(result.author);
  const description = present(result.description);
  const published = present(result.published);
  if (title !== undefined) articleMetadata.title = title;
  if (author !== undefined) articleMetadata.author = author;
  if (description !== undefined) articleMetadata.description = description;
  if (published !== undefined) articleMetadata.published = published;
  if (Number.isInteger(result.wordCount) && result.wordCount >= 0) {
    articleMetadata.wordCount = result.wordCount;
  }

  const payload = {
    requestID,
    outputPath,
    markdownByteCount: Buffer.byteLength(markdown, "utf-8"),
    metadata: { toolName: "defuddle" },
  };
  if (Object.keys(articleMetadata).length > 0) {
    payload.articleMetadata = articleMetadata;
  }
  emit("result", payload);
}

await main();
