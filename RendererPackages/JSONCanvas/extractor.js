// JSON Canvas 1.0 reference-extractor (manifest revision 5 assetRead
// authority). Runs inside the single-invocation RendererAssetReferenceExtractorHelper
// in an isolated JSContext (no DOM, filesystem, store, bridge, or network).
//
// Contract: `extract(input)` receives the pinned primary canvas text as one
// UTF-8 string argument and returns {records: [{role, reference}]}.
//
// The extractor returns ONLY `file` node values (role "imageNode") and group
// `background` values (role "groupBackground"). It performs no lookups, no
// enumeration, no network, no allocation beyond the bounded document. The
// records are validated again by the host (allowed roles, reference syntax,
// count, lengths, uniqueness, sibling membership) before any session exists.
//
// Changing this extractor's semantics requires new package bytes, a new
// version, new digests, and review.

__sdw_extract_canvas_assets = function (input) {
  "use strict";
  var doc;
  try {
    doc = JSON.parse(input);
  } catch (e) {
    return { records: [] };
  }
  var records = [];
  var seen = Object.create(null);
  function push(role, reference) {
    if (typeof reference !== "string") return;
    if (reference.length === 0 || reference.length > 512) return;
    var key = role + "\u0001" + reference;
    if (Object.prototype.hasOwnProperty.call(seen, key)) return;
    seen[key] = true;
    records.push({ role: role, reference: reference });
  }
  (doc.nodes || []).forEach(function (node) {
    if (!node || typeof node !== "object") return;
    var type = node.type;
    if (type === "file" && typeof node.file === "string") {
      push("imageNode", node.file);
    } else if (type === "group" && typeof node.background === "string") {
      push("groupBackground", node.background);
    }
  });
  return { records: records };
};
