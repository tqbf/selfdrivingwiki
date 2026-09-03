(function () {
  "use strict";

  // JSON Canvas 1.0 renderer (read-only, bounded, accessible).
  //
  // Pure staged architecture so the normal suite can execute the exact
  // package-owned parse/scene/geometry/layout stages in a fresh JavaScriptCore
  // context with no DOM/fetch/network/native objects:
  //   1. parseWire(bytes)          -> bounded document model (full JSON Canvas
  //                                   1.0 fields, closed-field validation)
  //   2. buildScene(doc)           -> scene model (bounds, node map, z-order)
  //   3. computeEdges(doc, scene)  -> side-aware anchors + Bezier control
  //                                   points + endpoint markers
  //   4. layoutText(doc, scene)    -> width-aware Markdown wrapping, clipped
  //                                   to node height
  //   5. resolveAssets(doc)        -> allowed asset.read requests
  //   6. render(scene, layout, ...)-> semantic SVG/HTML in the DOM
  //
  // The DOM path is production; the pure stages are the test seam. No
  // innerHTML, no network fetch, no arbitrary HTML, no transclusion.

  var hasDOM = typeof document !== "undefined" && typeof window !== "undefined";
  var viewer = hasDOM ? document.getElementById("viewer") : null;
  var namespace = "http://www.w3.org/2000/svg";
  var requestID = "json-canvas-initial-input";

  // Bounds (manifest sizeLimits + internal ceilings).
  var maximumInputBytes = 48000;
  var maximumNodeCount = 512;
  var maximumEdgeCount = 1024;
  var maximumIdentifierLength = 128;
  var maximumTextLength = 8192;
  var maximumCoordinateMagnitude = 1000000;
  var maximumKeyCount = 64;
  var maximumKeyLength = 64;
  var maximumValueLength = 8192;
  var maximumReferenceLength = 512;
  var maximumAssetCount = 256;

  var presetColors = { "1": "#e03131", "2": "#f08c00", "3": "#f5c415", "4": "#2b8a3e", "5": "#0c8599", "6": "#7048e8" };

  function makeSVG(name, attributes) {
    var node = document.createElementNS(namespace, name);
    Object.keys(attributes || {}).forEach(function (key) { node.setAttribute(key, String(attributes[key])); });
    return node;
  }

  function showMessage(text) {
    if (!viewer) return;
    viewer.replaceChildren(Object.assign(document.createElement("p"), { className: "message", textContent: text }));
  }

  function isFiniteNumber(value) { return typeof value === "number" && Number.isFinite(value); }

  function isValidColor(value) {
    if (typeof value !== "string") return false;
    if (Object.prototype.hasOwnProperty.call(presetColors, value)) return true;
    return /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(value);
  }

  function isCanonicalULID(value) {
    return typeof value === "string" && value.length === 26 && /^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]+$/.test(value);
  }

  // A file reference is a plain relative wiki name. Reject absolute paths,
  // traversal, tilde, backslashes, schemes, credentials, queries, percent
  // escapes, control characters, empty components, and whitespace padding.
  function isValidFileReference(value) {
    if (typeof value !== "string" || value.length === 0 || value.length > maximumIdentifierLength) return false;
    if (value !== value.trim()) return false;
    if (/[\u0000-\u001f\u007f]/.test(value)) return false;
    if (value.charAt(0) === "/" || value.charAt(0) === "~") return false;
    if (/[\\:@?#%]/.test(value)) return false;
    return value.split("/").every(function (component) {
      return component.length > 0 && component !== "." && component !== "..";
    });
  }

  function isAllowedSide(value) { return value === "top" || value === "right" || value === "bottom" || value === "left"; }
  function isAllowedEnd(value) { return value === "none" || value === "arrow"; }
  function isAllowedBackgroundStyle(value) { return value === "cover" || value === "ratio" || value === "repeat"; }
  function isAllowedNodeType(value) { return value === "text" || value === "file" || value === "link" || value === "group"; }

  // Bounded key/value/nesting limits before any traversal: reject a document
  // that would blow up recursion or allocation. Unknown top-level, node, and
  // edge properties are IGNORED (bounded forward-compatible extensions do not
  // suppress rendering), but the aggregate limits are enforced.
  function enforceBoundedShape(value, depth) {
    if (depth > 8) throw new Error("excessive nesting");
    if (value === null || typeof value !== "object") return;
    if (Array.isArray(value)) {
      if (value.length > maximumNodeCount * 2 + maximumEdgeCount * 2 + 32) throw new Error("excessive array size");
      for (var i = 0; i < value.length; i++) enforceBoundedShape(value[i], depth + 1);
      return;
    }
    var keys = Object.keys(value);
    if (keys.length > maximumKeyCount) throw new Error("excessive key count");
    for (var k = 0; k < keys.length; k++) {
      if (keys[k].length > maximumKeyLength) throw new Error("excessive key length");
      var val = value[keys[k]];
      if (typeof val === "string" && val.length > maximumValueLength) throw new Error("excessive value length");
      enforceBoundedShape(val, depth + 1);
    }
  }

  // Stage 1: bounded, spec-complete parse. Applies JSON Canvas defaults
  // (fromEnd = none, toEnd = arrow) and rejects unknown values for the closed
  // fields (type, sides, ends, backgroundStyle).
  function parseWire(bytes) {
    if (bytes.byteLength > maximumInputBytes) throw new Error("oversized input");
    var text = utf8Decode(bytes);
    var value;
    try { value = JSON.parse(text); }
    catch (_) { throw new Error("malformed document"); }
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("malformed document");
    enforceBoundedShape(value, 0);
    var nodesWire = value.nodes || [];
    var edgesWire = value.edges || [];
    if (!Array.isArray(nodesWire) || !Array.isArray(edgesWire)) throw new Error("malformed document");
    if (nodesWire.length > maximumNodeCount) throw new Error("too many nodes");
    if (edgesWire.length > maximumEdgeCount) throw new Error("too many edges");

    var seenNodeIDs = Object.create(null);
    var nodes = nodesWire.map(function (wire) {
      if (wire === null || typeof wire !== "object" || Array.isArray(wire)) throw new Error("malformed document");
      if (typeof wire.id !== "string" || wire.id.length === 0 || wire.id.length > maximumIdentifierLength) throw new Error("invalid node id");
      if (Object.prototype.hasOwnProperty.call(seenNodeIDs, wire.id)) throw new Error("duplicate node id");
      seenNodeIDs[wire.id] = true;
      if (typeof wire.type !== "string" || !isAllowedNodeType(wire.type)) throw new Error("invalid node type");
      var x = wire.x, y = wire.y, width = wire.width, height = wire.height;
      if (!isFiniteNumber(x) || !isFiniteNumber(y) || !isFiniteNumber(width) || !isFiniteNumber(height)) throw new Error("invalid geometry");
      if (Math.abs(x) > maximumCoordinateMagnitude || Math.abs(y) > maximumCoordinateMagnitude ||
          width <= 0 || height <= 0 || width > maximumCoordinateMagnitude || height > maximumCoordinateMagnitude) throw new Error("invalid geometry");
      if (wire.color !== undefined && !isValidColor(wire.color)) throw new Error("invalid color");
      var type = wire.type;
      var textValue = "";
      var file = null, subpath = null, url = null, label = "", background = null, backgroundStyle = null, backgroundReference = null;
      if (type === "text") {
        if (typeof wire.text !== "string") throw new Error("malformed document");
        textValue = wire.text;
      } else if (type === "file") {
        if (!isValidFileReference(wire.file)) throw new Error("invalid internal link");
        file = wire.file;
        if (wire.subpath !== undefined) {
          if (typeof wire.subpath !== "string" || wire.subpath.length === 0 || wire.subpath.length > maximumTextLength ||
              wire.subpath.charAt(0) !== "#" || /[?#%]/.test(wire.subpath.slice(1)) || /[\u0000-\u001f\u007f]/.test(wire.subpath)) throw new Error("invalid internal link");
          subpath = wire.subpath;
        }
        textValue = file;
      } else if (type === "link") {
        if (typeof wire.url !== "string") throw new Error("invalid internal link");
        url = wire.url;
        if (/^\[\[(page|source):[A-Z0-9]+\]\]$/.test(url)) {
          var wikiMatch = url.match(/^\[\[(page|source):([A-Z0-9]+)\]\]$/);
          if (!isCanonicalULID(wikiMatch[2])) throw new Error("invalid internal link");
          textValue = url;
        } else if (/^https?:\/\//i.test(url)) {
          textValue = url;
        } else {
          throw new Error("invalid internal link");
        }
      } else if (type === "group") {
        if (wire.label !== undefined && (typeof wire.label !== "string" || wire.label.length > maximumTextLength)) {
          throw new Error("text too large");
        }
        label = typeof wire.label === "string" ? wire.label : "";
        if (wire.background !== undefined) {
          // The background is an image path (a relative content reference),
          // not a color.
          if (!isValidFileReference(wire.background)) throw new Error("invalid background");
          backgroundReference = wire.background;
          background = null;
        }
        if (wire.backgroundStyle !== undefined && !isAllowedBackgroundStyle(wire.backgroundStyle)) {
          throw new Error("malformed document");
        }
        backgroundStyle = wire.backgroundStyle || "cover";
      } else {
        throw new Error("unsupported node type");
      }
      if ((textValue || label).length > maximumTextLength) throw new Error("text too large");
      return {
        id: wire.id, type: type, x: x, y: y, width: width, height: height,
        text: textValue, color: wire.color, file: file, subpath: subpath, url: url,
        label: label, background: background, backgroundReference: backgroundReference,
        backgroundStyle: backgroundStyle
      };
    });

    var seenEdgeIDs = Object.create(null);
    var edges = edgesWire.map(function (wire) {
      if (wire === null || typeof wire !== "object" || Array.isArray(wire)) throw new Error("malformed document");
      if (typeof wire.id !== "string" || wire.id.length === 0 || wire.id.length > maximumIdentifierLength) throw new Error("duplicate edge id");
      if (Object.prototype.hasOwnProperty.call(seenEdgeIDs, wire.id)) throw new Error("duplicate edge id");
      seenEdgeIDs[wire.id] = true;
      if (typeof wire.fromNode !== "string" || typeof wire.toNode !== "string" ||
          !Object.prototype.hasOwnProperty.call(seenNodeIDs, wire.fromNode) || !Object.prototype.hasOwnProperty.call(seenNodeIDs, wire.toNode)) {
        throw new Error("unknown edge endpoint");
      }
      if (wire.fromSide !== undefined && !isAllowedSide(wire.fromSide)) throw new Error("invalid edge side");
      if (wire.toSide !== undefined && !isAllowedSide(wire.toSide)) throw new Error("invalid edge side");
      if (wire.fromEnd !== undefined && !isAllowedEnd(wire.fromEnd)) throw new Error("invalid edge end");
      if (wire.toEnd !== undefined && !isAllowedEnd(wire.toEnd)) throw new Error("invalid edge end");
      if (wire.color !== undefined && !isValidColor(wire.color)) throw new Error("invalid color");
      if (wire.label !== undefined && (typeof wire.label !== "string" || wire.label.length > maximumTextLength)) throw new Error("text too large");
      return {
        id: wire.id, fromNode: wire.fromNode, fromSide: wire.fromSide || null,
        fromEnd: wire.fromEnd || "none", toNode: wire.toNode, toSide: wire.toSide || null,
        toEnd: wire.toEnd || "arrow", color: wire.color, label: wire.label || null
      };
    });

    return { nodes: nodes, edges: edges };
  }

  // Stage 2: scene model — whole-canvas bounds (nodes, edges, labels),
  // node map, ascending z-order (first node lowest, last node highest).
  function buildScene(doc) {
    var nodeById = Object.create(null);
    doc.nodes.forEach(function (node) { nodeById[node.id] = node; });
    var bounds = { x: Number.POSITIVE_INFINITY, y: Number.POSITIVE_INFINITY,
                   right: Number.NEGATIVE_INFINITY, bottom: Number.NEGATIVE_INFINITY };
    function include(x, y) {
      if (x < bounds.x) bounds.x = x;
      if (y < bounds.y) bounds.y = y;
      if (x > bounds.right) bounds.right = x;
      if (y > bounds.bottom) bounds.bottom = y;
    }
    doc.nodes.forEach(function (node) {
      include(node.x, node.y);
      include(node.x + node.width, node.y + node.height);
    });
    // Edges and labels extend the bounds.
    doc.edges.forEach(function (edge) {
      var from = nodeById[edge.fromNode], to = nodeById[edge.toNode];
      if (!from || !to) return;
      var fromPoint = sideAnchor(from, edge.fromSide);
      var toPoint = sideAnchor(to, edge.toSide);
      include(fromPoint.x, fromPoint.y);
      include(toPoint.x, toPoint.y);
    });
    if (doc.nodes.length === 0 && doc.edges.length === 0) {
      bounds = { x: 0, y: 0, right: 1, bottom: 1 };
    } else {
      if (bounds.x === Number.POSITIVE_INFINITY) bounds.x = 0;
      if (bounds.y === Number.POSITIVE_INFINITY) bounds.y = 0;
      if (bounds.right === Number.NEGATIVE_INFINITY) bounds.right = bounds.x + 1;
      if (bounds.bottom === Number.NEGATIVE_INFINITY) bounds.bottom = bounds.y + 1;
    }
    return { doc: doc, nodeById: nodeById, bounds: bounds };
  }

  // Choose the nearest pair of facing rectangle boundaries for an omitted
  // side. Comparing gaps avoids treating a diagonal edge as horizontal just
  // because the node centers are farther apart on the x axis.
  function automaticSide(node, other) {
    if (!other) return null;
    var cx = node.x + node.width / 2;
    var cy = node.y + node.height / 2;
    var ox = other.x + other.width / 2;
    var oy = other.y + other.height / 2;
    var dx = ox - cx;
    var dy = oy - cy;
    var horizontalGap = Math.max(0, Math.max(node.x - (other.x + other.width), other.x - (node.x + node.width)));
    var verticalGap = Math.max(0, Math.max(node.y - (other.y + other.height), other.y - (node.y + node.height)));
    if (verticalGap === 0 && horizontalGap > 0) {
      return dx >= 0 ? "right" : "left";
    }
    if (horizontalGap === 0 && verticalGap > 0) {
      return dy >= 0 ? "bottom" : "top";
    }
    if (horizontalGap < verticalGap || (horizontalGap === verticalGap && Math.abs(dx) >= Math.abs(dy))) {
      return dx >= 0 ? "right" : "left";
    }
    return dy >= 0 ? "bottom" : "top";
  }

  // Rectangle-boundary anchor for an explicit side (or a deterministic
  // automatic side when absent).
  function sideAnchor(node, side, other) {
    var cx = node.x + node.width / 2;
    var cy = node.y + node.height / 2;
    var resolved = side || automaticSide(node, other);
    switch (resolved) {
      case "top": return { x: cx, y: node.y };
      case "bottom": return { x: cx, y: node.y + node.height };
      case "left": return { x: node.x, y: cy };
      case "right": return { x: node.x + node.width, y: cy };
      default: return { x: cx, y: cy };
    }
  }

  // Stage 3: edge geometry. Cubic Bezier control points adapted from
  // JSON-Canvas-Viewer (MIT) and rewritten to this data model. The parallel
  // offset moves the curve's endpoint slightly outside the node so the
  // arrowhead's tip sits ON the boundary and the path does not enter the node
  // interior. Deterministic automatic sides when absent.
  function computeEdgeGeometry(from, to, fromSide, toSide) {
    var fromPoint = sideAnchor(from, fromSide, to);
    var toPoint = sideAnchor(to, toSide, from);

    // Direction vectors: outer normal of the leaving side and outer normal of
    // the arriving side.
    var fromDir = sideDirection(from, fromSide, to);
    var toDir = sideDirection(to, toSide, from);

    // Control points: extend along the side normal.
    var tangent = 0.5 * Math.min(Math.max(Math.abs(toPoint.x - fromPoint.x) / 2, 40), 200);
    var c1x = fromPoint.x + fromDir.x * tangent;
    var c1y = fromPoint.y + fromDir.y * tangent;
    var c2x = toPoint.x + toDir.x * tangent;
    var c2y = toPoint.y + toDir.y * tangent;

    return {
      from: fromPoint, to: toPoint,
      control1: { x: c1x, y: c1y }, control2: { x: c2x, y: c2y },
      path: "M " + fromPoint.x + " " + fromPoint.y +
            " C " + c1x + " " + c1y + ", " + c2x + " " + c2y + ", " + toPoint.x + " " + toPoint.y
    };
  }

  function sideDirection(node, side, other) {
    var resolved = side || automaticSide(node, other);
    switch (resolved) {
      case "top": return { x: 0, y: -1 };
      case "bottom": return { x: 0, y: 1 };
      case "left": return { x: -1, y: 0 };
      case "right": return { x: 1, y: 0 };
      default: return { x: 0, y: 0 };
    }
  }

  // Deterministic edge midpoint for label placement (parametric t=0.5 on the
  // cubic).
  function bezierMidpoint(geometry) {
    var x = (geometry.from.x + 3 * geometry.control1.x + 3 * geometry.control2.x + geometry.to.x) / 8;
    var y = (geometry.from.y + 3 * geometry.control1.y + 3 * geometry.control2.y + geometry.to.y) / 8;
    return { x: x, y: y };
  }

  // Stage 4: bounded Markdown tokenizer for text nodes. Supported grammar:
  // paragraphs, explicit newlines, emphasis, strong emphasis, inline code,
  // and links. Headings, lists, block quotes, fenced code, images, raw HTML,
  // tables, footnotes, transclusion, and unknown constructs are escaped plain
  // text. Returns semantic spans. Deterministic font metrics + width-aware
  // wrapping + node-height clipping with an explicit overflow cue.
  function tokenizeMarkdown(text) {
    var tokens = [];
    var i = 0;
    function pushText(value) {
      if (value.length === 0) return;
      var last = tokens[tokens.length - 1];
      if (last && last.type === "text") last.value += value;
      else tokens.push({ type: "text", value: value });
    }
    while (i < text.length) {
      var ch = text[i];
      if (ch === "\n") {
        tokens.push({ type: "break" });
        i += 1;
      } else if (ch === "`") {
        var end = text.indexOf("`", i + 1);
        if (end === -1) { pushText(ch); i += 1; }
        else {
          var code = text.slice(i + 1, end);
          if (code.indexOf("`") !== -1 || code.length > maximumTextLength) { pushText(ch); i += 1; }
          else { tokens.push({ type: "code", value: code }); i = end + 1; }
        }
      } else if (ch === "*" || ch === "_") {
        var strong = text[i + 1] === ch;
        var marker = strong ? ch + ch : ch;
        var closer = text.indexOf(marker, i + marker.length);
        if (closer === -1 || (strong && closer === i + 2)) { pushText(ch); i += 1; }
        else {
          var inner = text.slice(i + marker.length, closer);
          if (inner.indexOf(marker) !== -1) { pushText(ch); i += 1; }
          else { tokens.push({ type: strong ? "strong" : "em", value: inner }); i = closer + marker.length; }
        }
      } else if (ch === "[") {
        var linkClose = text.indexOf("]", i + 1);
        if (linkClose === -1 || text[linkClose + 1] !== "(") { pushText(ch); i += 1; }
        else {
          var parenEnd = text.indexOf(")", linkClose + 2);
          if (parenEnd === -1) { pushText(ch); i += 1; }
          else {
            var label = text.slice(i + 1, linkClose);
            var href = text.slice(linkClose + 2, parenEnd);
            if (label.length > maximumTextLength || href.length > maximumTextLength) { pushText(ch); i += 1; }
            else { tokens.push({ type: "link", value: label, href: href }); i = parenEnd + 1; }
          }
        }
      } else {
        pushText(ch);
        i += 1;
      }
    }
    return tokens;
  }

  // Width-aware wrap: estimate glyph widths deterministically (no canvas;
  // average ASCII ~0.55em, wide chars ~1em), break on spaces, and clip to the
  // node height with an explicit overflow cue. Returns lines of tokens.
  function wrapTokens(tokens, width) {
    var lines = [];
    var current = [];
    var currentWidth = 0;
    var glyphWidth = function (value) {
      var w = 0;
      for (var c = 0; c < value.length; c++) {
        var code = value.charCodeAt(c);
        w += (code > 0x2e80 || code >= 0x1100) ? 1 : 0.55;
      }
      return w;
    };
    function flush() {
      if (current.length > 0) { lines.push(current); current = []; currentWidth = 0; }
    }
    tokens.forEach(function (token) {
      if (token.type === "break") { flush(); return; }
      var tw = glyphWidth(token.value || "");
      if (currentWidth + tw > width && currentWidth > 0) flush();
      current.push(token);
      currentWidth += tw;
    });
    flush();
    return lines;
  }

  // Clip lines to the node height (13px line height + padding). Returns the
  // visible lines plus an overflow flag.
  function clipLines(lines, height) {
    var lineHeight = 16;
    var maxLines = Math.max(1, Math.floor((height - 8) / lineHeight));
    var visible = lines.slice(0, maxLines);
    return { lines: visible, overflow: lines.length > maxLines };
  }

  // Stage 5: asset requests from file nodes (imageNode) and group
  // background references (groupBackground). Only allowlisted relative
  // references are requested; everything else is a readable fallback.
  function resolveAssets(doc) {
    var requests = [];
    var seen = Object.create(null);
    doc.nodes.forEach(function (node) {
      var request = null;
      if (node.type === "file" && node.file && isValidFileReference(node.file)) {
        request = { role: "imageNode", reference: node.file };
      } else if (node.type === "group" && node.backgroundReference) {
        request = { role: "groupBackground", reference: node.backgroundReference };
      }
      if (request && Object.prototype.hasOwnProperty.call(seen, request.reference) === false) {
        seen[request.reference] = true;
        requests.push(request);
      }
    });
    return requests;
  }

  function nodeTarget(wire) {
    if (wire.type === "link" && wire.url) {
      var wikiMatch = wire.url.match(/^\[\[(page|source):([A-Z0-9]+)\]\]$/);
      if (wikiMatch) {
        if (wikiMatch[1] === "page") return { page: { _0: { rawValue: wikiMatch[2] } } };
        return { source: { _0: { rawValue: wikiMatch[2] } } };
      }
    }
    if (wire.type === "file" && typeof wire.file === "string") {
      return { namedContent: { _0: { path: wire.file, subpath: wire.subpath || null } } };
    }
    return null;
  }

  function externalHref(wire) {
    if (wire.type === "link" && typeof wire.url === "string" && /^https?:\/\//i.test(wire.url)) return wire.url;
    return null;
  }

  function edgeColor(color) { return isValidColor(color) ? (presetColors[color] || color) : "currentColor"; }

  /// Pure marker assignment: returns {edgeId: {from: markerId|null, to: markerId|null}}
  /// and {markerId: colorKey} for the given scene. No DOM. Colored edges get a
  /// per-color marker; default (no-color) arrowheads share the "default"
  /// marker whose color is driven by CSS.
  function computeEdgeMarkers(doc) {
    var markerByColor = Object.create(null);
    var markers = Object.create(null);
    var edges = Object.create(null);
    function markerFor(color) {
      if (color == null) color = "default";
      if (markerByColor[color]) return markerByColor[color];
      var id = "sdw-arrowhead-" + (Object.keys(markerByColor).length + 1);
      markerByColor[color] = id;
      markers[id] = color;
      return id;
    }
    doc.edges.forEach(function (edge) {
      edges[edge.id] = {
        from: edge.fromEnd === "arrow" ? markerFor(edge.color) : null,
        to: edge.toEnd === "arrow" ? markerFor(edge.color) : null
      };
    });
    return { edges: edges, markers: markers };
  }

  /// DOM wrapper: build the `defs` <marker> elements per the pure assignment.
  function makeEdgeMarkers(scene) {
    var assignment = computeEdgeMarkers(scene.doc);
    var defs = makeSVG("defs");
    Object.keys(assignment.markers).forEach(function (id) {
      var color = assignment.markers[id];
      var marker = makeSVG("marker", { id: id, markerWidth: "8", markerHeight: "8", refX: "6", refY: "3", orient: "auto-start-reverse", markerUnits: "strokeWidth" });
      var arrowColor = color === "default" ? "currentColor" : edgeColor(color);
      if (color !== "default") marker.setAttribute("color", arrowColor);
      else marker.setAttribute("class", "edge-arrow-default");
      var arrow = makeSVG("path", { d: "M0,0 L6,3 L0,6 z", class: "edge-arrow", fill: arrowColor });
      marker.append(arrow);
      defs.append(marker);
    });
    scene.doc.edges.forEach(function (edge) {
      var e = assignment.edges[edge.id];
      edge.__markerFrom = e.from;
      edge.__markerTo = e.to;
    });
    defs.__sdwMarkerInfo = assignment.markers;
    return defs;
  }

  // Stage 6: render semantic SVG/HTML. Nodes in ascending z-order (first
  // lowest, last highest); edges beneath nodes; group backgrounds behind
  // contained content; readable text; image nodes via asset.read; fallbacks
  // for denied/unavailable images.
  function render(scene, layout, callback) {
    var svg = makeSVG("svg", { class: "scene", role: "group", "aria-label": "Read-only JSON Canvas, use arrow keys to pan and plus or minus to zoom" });
    var defs = makeEdgeMarkers(scene);
    var sceneG = makeSVG("g", { class: "scene-layer" });

    // Edge labels + paths beneath nodes, in array order.
    scene.doc.edges.forEach(function (edge) {
      var from = scene.nodeById[edge.fromNode], to = scene.nodeById[edge.toNode];
      if (!from || !to) return;
      var geometry = computeEdgeGeometry(from, to, edge.fromSide, edge.toSide);
      var path = makeSVG("path", {
        class: edge.color ? "edge" : "edge edge-default", d: geometry.path,
        stroke: edge.color ? edgeColor(edge.color) : "currentColor",
        fill: "none"
      });
      // Keep colored strokes as literal SVG presentation attributes. WebKit
      // can report an inline CSS stroke from getComputedStyle() while still
      // painting the competing class stroke. Only uncolored edges receive the
      // CSS class that supplies the theme-aware default gray.
      if (edge.toEnd === "arrow" && edge.__markerTo) path.setAttribute("marker-end", "url(#" + edge.__markerTo + ")");
      if (edge.fromEnd === "arrow" && edge.__markerFrom) path.setAttribute("marker-start", "url(#" + edge.__markerFrom + ")");
      sceneG.append(path);
      if (edge.label) {
        var mid = bezierMidpoint(geometry);
        var labelG = makeSVG("g", { class: "edge-label-wrap", transform: "translate(" + mid.x + " " + mid.y + ")" });
        var bg = makeSVG("rect", { class: "edge-label-bg", x: -30, y: -10, width: 60, height: 20, rx: 4 });
        var labelNode = makeSVG("text", { class: "edge-label", x: 0, y: 3, "text-anchor": "middle" });
        labelNode.textContent = edge.label;
        labelG.append(bg, labelNode);
        sceneG.append(labelG);
      }
    });

    // Nodes in ascending z-order.
    scene.doc.nodes.forEach(function (node) {
      var href = externalHref(node);
      var wrapped = href
        ? makeSVG("a", { href: href, class: "node-anchor" })
        : makeSVG("g", { class: "node-wrapper" });
      // Group background first (behind contained content), then frame.
      if (node.type === "group" && node.backgroundReference) {
        var bgImage = makeSVG("image", {
          class: "node-group-bg", x: node.x, y: node.y, width: node.width, height: node.height,
          preserveAspectRatio: node.backgroundStyle === "cover" ? "xMidYMid slice" : (node.backgroundStyle === "ratio" ? "xMidYMid meet" : "none"),
          "data-asset-role": "groupBackground", "data-asset-reference": node.backgroundReference
        });
        if (callback && callback.imageURLFor(node.backgroundReference)) bgImage.setAttribute("href", callback.imageURLFor(node.backgroundReference));
        wrapped.append(bgImage);
      }
      var rect = makeSVG("rect", { class: "node", x: node.x, y: node.y, width: node.width, height: node.height, fill: "transparent", stroke: nodeStroke(node) });
      if (node.type === "group" && node.background) {
        rect.setAttribute("fill", edgeColor(node.background));
      }
      wrapped.append(rect);

      if (node.type === "text") {
        // semantic HTML inside a node-bounded foreignObject + offscreen
        // fallback for WebKit accessibility.
        var lines = layout.lines[node.id] || [];
        var fo = makeSVG("foreignObject", { class: "node-text-fo", x: node.x + 8, y: node.y + 4, width: Math.max(0, node.width - 16), height: Math.max(0, node.height - 8) });
        var html = document.createElement("div");
        html.setAttribute("class", "node-text");
        html.setAttribute("lang", "en");
        lines.forEach(function (lineTokens, index) {
          var p = document.createElement("p");
          lineTokens.forEach(function (token) {
            if (token.type === "text") p.append(document.createTextNode(token.value));
            else if (token.type === "code") {
              var code = document.createElement("code");
              code.textContent = token.value;
              p.append(code);
            } else if (token.type === "em") {
              var em = document.createElement("em");
              em.textContent = token.value;
              p.append(em);
            } else if (token.type === "strong") {
              var strong = document.createElement("strong");
              strong.textContent = token.value;
              p.append(strong);
            } else if (token.type === "link") {
              var a = document.createElement("a");
              a.textContent = token.value;
              a.setAttribute("href", "#");
              a.setAttribute("class", "markdown-link");
              var internalTarget = heroTarget(node.url, token.href);
              if (internalTarget) {
                a.setAttribute("data-renderer-host-navigation", JSON.stringify(internalTarget));
                a.setAttribute("tabindex", "0");
              } else if (/^https?:\/\//i.test(token.href)) {
                a.setAttribute("data-external-href", token.href);
                a.setAttribute("tabindex", "0");
              }
              p.append(a);
            }
          });
          html.append(p);
        });
        if (layout.overflow[node.id]) {
          var cue = document.createElement("p");
          cue.setAttribute("class", "overflow-cue");
          cue.textContent = "…";
          html.append(cue);
        }
        fo.append(html);
        wrapped.append(fo);
        // SVG <title>/<desc> for VoiceOver.
        var title = makeSVG("title");
        title.textContent = node.text || "Text node";
        var desc = makeSVG("desc");
        desc.textContent = "Read-only text. " + node.text;
        wrapped.append(title, desc);
      } else if (node.type === "file") {
        var fileImage = makeSVG("image", {
          class: "node-file-image", x: node.x + 4, y: node.y + 4,
          width: Math.max(0, node.width - 8), height: Math.max(0, node.height - 8),
          preserveAspectRatio: "xMidYMid meet",
          "data-asset-role": "imageNode", "data-asset-reference": node.file
        });
        if (callback && callback.imageURLFor(node.file)) fileImage.setAttribute("href", callback.imageURLFor(node.file));
        wrapped.append(fileImage);
        var fileLabel = makeSVG("text", { class: "node-label", x: node.x + 8, y: node.y + node.height - 6 });
        fileLabel.textContent = node.text || node.file;
        wrapped.append(fileLabel);
        var fileTitle = makeSVG("title");
        fileTitle.textContent = node.file;
        wrapped.append(fileTitle);
      } else if (node.type === "link") {
        var linkLabel = makeSVG("text", { class: "node-label", x: node.x + 8, y: node.y + 20 });
        linkLabel.textContent = node.text || node.url;
        wrapped.append(linkLabel);
      } else if (node.type === "group") {
        var groupLabel = makeSVG("text", { class: "node-label", x: node.x + 8, y: node.y + 20 });
        groupLabel.textContent = node.label || "";
        wrapped.append(groupLabel);
        var groupTitle = makeSVG("title");
        groupTitle.textContent = node.label || "Group";
        wrapped.append(groupTitle);
      }

      var target = nodeTarget(node);
      if (target) {
        wrapped.setAttribute("data-renderer-host-navigation", JSON.stringify(target));
        wrapped.setAttribute("tabindex", "0");
        wrapped.setAttribute("role", "link");
        wrapped.setAttribute("aria-label", node.text || node.label || "Open canvas node");
      }
      if (href) {
        wrapped.setAttribute("aria-label", node.text || "Open external link");
      }
      sceneG.append(wrapped);
    });

    // Node fill: native-like tinted fills for colored nodes, transparent
    // otherwise; independent stroke.
    function nodeStroke(node) {
      if (node.color !== undefined) return edgeColor(node.color);
      return "currentColor";
    }

    svg.append(defs, sceneG);
    if (viewer) viewer.replaceChildren(svg);

    // Fit-to-window: measured viewport + full scene bounds, node strokes +
    // edge paths/markers + labels included; clamp scale to named limits.
    var view = fitView(scene.bounds, viewer ? viewer.clientWidth : 800, viewer ? viewer.clientHeight : 600);
    function applyView() { sceneG.setAttribute("transform", "translate(" + view.x + " " + view.y + ") scale(" + view.scale + ")"); }
    applyView();

    bindInteraction(svg, viewer, sceneG, view);
    if (callback && callback.onRendered) callback.onRendered();
  }

  function fitView(bounds, windowWidth, windowHeight) {
    var padding = 24;
    var contentWidth = Math.max(1, bounds.right - bounds.x);
    var contentHeight = Math.max(1, bounds.bottom - bounds.y);
    var availableWidth = Math.max(1, windowWidth - padding * 2);
    var availableHeight = Math.max(1, windowHeight - padding * 2);
    var scale = Math.min(availableWidth / contentWidth, availableHeight / contentHeight, 1);
    scale = clamp(scale, 0.25, 4);
    var x = (windowWidth - contentWidth * scale) / 2 - bounds.x * scale;
    var y = (windowHeight - contentHeight * scale) / 2 - bounds.y * scale;
    return { scale: scale, x: x, y: y };
  }

  function clamp(value, min, max) { return Math.min(max, Math.max(min, value)); }

  function bindInteraction(svg, viewer, sceneG, view) {
    var minimumScale = 0.25, maximumScale = 4, zoomFactor = 1.1, keyboardPanStep = 32;
    function applyView() { sceneG.setAttribute("transform", "translate(" + view.x + " " + view.y + ") scale(" + view.scale + ")"); }
    function setScale(next) { view.scale = clamp(next, minimumScale, maximumScale); }
    var drag = null;
    svg.addEventListener("pointerdown", function (event) {
      if (event.target.closest("a")) return;
      viewer.focus({ preventScroll: true });
      drag = { x: event.clientX, y: event.clientY, viewX: view.x, viewY: view.y };
      svg.setPointerCapture(event.pointerId);
    });
    svg.addEventListener("pointermove", function (event) {
      if (!drag) return;
      view.x = drag.viewX + event.clientX - drag.x;
      view.y = drag.viewY + event.clientY - drag.y;
      applyView();
    });
    svg.addEventListener("pointerup", function () { drag = null; });
    svg.addEventListener("pointercancel", function () { drag = null; });
    svg.addEventListener("wheel", function (event) {
      if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
      event.preventDefault();
      var rect = svg.getBoundingClientRect();
      var pointerX = event.clientX - rect.left;
      var pointerY = event.clientY - rect.top;
      var previous = view.scale;
      var next = event.deltaY < 0 ? previous * zoomFactor : previous / zoomFactor;
      setScale(next);
      if (view.scale === previous) return;
      var documentX = (pointerX - view.x) / previous;
      var documentY = (pointerY - view.y) / previous;
      view.x = pointerX - documentX * view.scale;
      view.y = pointerY - documentY * view.scale;
      applyView();
    }, { passive: false });
    if (viewer) viewer.addEventListener("keydown", function (event) {
      switch (event.key) {
        case "ArrowDown": view.y -= keyboardPanStep; break;
        case "ArrowLeft": view.x += keyboardPanStep; break;
        case "ArrowRight": view.x -= keyboardPanStep; break;
        case "ArrowUp": view.y += keyboardPanStep; break;
        case "+":
        case "=": setScale(view.scale * zoomFactor); break;
        case "-":
        case "_": setScale(view.scale / zoomFactor); break;
        case "0": setScale(1); break;
        default: return;
      }
      event.preventDefault();
      applyView();
    });
  }

  function heroTarget(nodeURL, href) {
    // Internal Markdown links: canonical [[page:ID]] / [[source:ID]] only.
    var match = href.match(/^\[\[(page|source):([A-Z0-9]+)\]\]$/);
    if (match && isCanonicalULID(match[2])) {
      if (match[1] === "page") return { page: { _0: { rawValue: match[2] } } };
      return { source: { _0: { rawValue: match[2] } } };
    }
    return null;
  }

  // ---- Bridge integration (production) ----

  function byteStringToText(encoded) {
    var bytes = Uint8Array.from(atob(encoded), function (character) { return character.charCodeAt(0); });
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }

  function readAuthorizedInput() {
    var rawInput = document.documentElement.dataset.rendererInput;
    if (!rawInput) { showMessage("The authorized canvas input is unavailable."); return; }
    var input;
    try { input = JSON.parse(rawInput); }
    catch (_) { showMessage("The authorized canvas input is unavailable."); return; }
    window.addEventListener("message", function receiveInput(event) {
      var response = event.data && event.data.rendererBridgeResponse;
      if (typeof response !== "string") return;
      try {
        var decoded = JSON.parse(response);
        if (decoded.id !== requestID || !decoded.payload || typeof decoded.payload.bytes !== "string") return;
        window.removeEventListener("message", receiveInput);
        renderDocument(byteStringToText(decoded.payload.bytes));
      } catch (_) {
        showMessage("This canvas could not be read.");
      }
    });
    window.postMessage({ rendererBridge: JSON.stringify({ id: requestID, method: "input.read", input: input }) }, "*");
  }

  // Full pipeline used by both the DOM path and (via the pure stages) the
  // host bridge. Assets resolved through asset.read (allowlisted by the host).
  function renderDocument(wireText) {
    var bytes = new TextEncoder().encode(wireText);
    var doc = parseWire(bytes);
    var scene = buildScene(doc);
    var layout = layoutDocument(doc, scene);
    var assetRequests = resolveAssets(doc);
    var assetURLs = Object.create(null);
    // Revoke a Blob URL on replacement, failure, or teardown.
    function revokeAsset(reference) {
      var url = assetURLs[reference];
      if (url) {
        try { URL.revokeObjectURL(url); } catch (_) {}
        delete assetURLs[reference];
      }
    }
    // Request admitted assets through asset.read and render when images
    // arrive; unavailable assets keep the readable fallback.
    if (hasDOM && assetRequests.length > 0) {
      requestAssets(assetRequests, function (reference, mime, bytes) {
        try {
          var blob = new Blob([bytes], { type: mime });
          var url = URL.createObjectURL(blob);
          // Replace any prior URL for the same reference.
          if (assetURLs[reference]) revokeAsset(reference);
          assetURLs[reference] = url;
          var images = viewer.querySelectorAll('[data-asset-reference="' + CSS.escape(reference) + '"]');
          images.forEach(function (image) { image.setAttribute("href", url); });
        } catch (_) {
          revokeAsset(reference); // fallback stays
        }
      });
    }
    if (hasDOM) {
      // Teardown: revoke every Blob URL when the session page goes away.
      var onUnload = function () {
        Object.keys(assetURLs).forEach(function (reference) { revokeAsset(reference); });
      };
      window.addEventListener("pagehide", onUnload);
      window.addEventListener("beforeunload", onUnload);
    }
    render(scene, layout, {
      imageURLFor: function (reference) { return assetURLs[reference] || null; }
    });
  }

  function layoutDocument(doc, scene) {
    var lines = Object.create(null);
    var overflow = Object.create(null);
    doc.nodes.forEach(function (node) {
      if (node.type !== "text") return;
      var tokens = tokenizeMarkdown(node.text);
      var wrapped = wrapTokens(tokens, node.width - 16);
      var clipped = clipLines(wrapped, node.height);
      lines[node.id] = clipped.lines;
      overflow[node.id] = clipped.overflow;
    });
    return { lines: lines, overflow: overflow };
  }

  function requestAssets(requests, onAsset) {
    // Each asset.read uses a unique request ID; the bridge authorizer's
    // replay ledger accepts fresh IDs only.
    requests.forEach(function (request, index) {
      var assetRequestID = requestID + "-asset-" + index;
      var settled = false;
      function cleanup() {
        if (settled) return;
        settled = true;
        window.removeEventListener("message", listener);
        if (timeoutHandle) clearTimeout(timeoutHandle);
      }
      var timeoutHandle = setTimeout(cleanup, 5000);
      var listener = function (event) {
        var response = event.data && event.data.rendererBridgeResponse;
        if (typeof response !== "string") return;
        try {
          var decoded = JSON.parse(response);
          if (decoded.id !== assetRequestID) return;
          cleanup(); // remove on EVERY terminal matching-ID response
          var payload = decoded.payload;
          if (!payload || typeof payload.bytes !== "string" || typeof payload.mimeType !== "string") return;
          var bytes = Uint8Array.from(atob(payload.bytes), function (c) { return c.charCodeAt(0); });
          onAsset(request.reference, payload.mimeType, bytes);
        } catch (_) {
          cleanup(); // malformed payload: stop listening, keep the fallback
        }
      };
      window.addEventListener("message", listener);
      window.postMessage({ rendererBridge: JSON.stringify({
        id: assetRequestID, method: "asset.read",
        reference: request.reference
      }) }, "*");
    });
  }

  if (hasDOM) readAuthorizedInput();

  // ---- Production-inert test seam ----
  // Exposes the pure stages (parse, scene, geometry, layout) so the normal
  // suite can execute the EXACT package-owned logic in a fresh context with
  // no DOM/fetch/network/native objects. Not called from the production path.

  // JSC has no atob/TextEncoder/TextDecoder; provide plain equivalents
  // (ASCII/simple UTF-8, bounded by the frame limits) so the seams work in
  // both contexts.
  var decodeBase64 = (typeof atob !== "undefined")
    ? atob
    : function (base64) {
        // Minimal base64 decoder (standard alphabet, no whitespace) for
        // the JSC harness. Inputs are host-generated base64 of UTF-8 JSON.
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var out = "";
        var buffer = 0, bits = 0;
        for (var i = 0; i < base64.length; i++) {
          if (base64[i] === "=") break;
          var idx = chars.indexOf(base64[i]);
          if (idx === -1) continue;
          buffer = (buffer << 6) | idx;
          bits += 6;
          if (bits >= 8) {
            bits -= 8;
            out += String.fromCharCode((buffer >> bits) & 0xff);
          }
        }
        return out;
      };
  function base64ToBytes(base64) {
    var binary = decodeBase64(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }
  function utf8Encode(text) {
    if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(text);
    var bytes = [];
    for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i) & 0xff);
    return Uint8Array.from(bytes);
  }
  function utf8Decode(bytes) {
    if (typeof TextDecoder !== "undefined") {
      return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    }
    // JSC fallback: decode UTF-8 (multi-byte sequences) from the byte array.
    var out = "";
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i];
      var codePoint;
      var extra;
      if (b < 0x80) { codePoint = b; extra = 0; }
      else if ((b & 0xe0) === 0xc0) { codePoint = b & 0x1f; extra = 1; }
      else if ((b & 0xf0) === 0xe0) { codePoint = b & 0x0f; extra = 2; }
      else if ((b & 0xf8) === 0xf0) { codePoint = b & 0x07; extra = 3; }
      else throw new Error("malformed document");
      var valid = extra + 1 <= bytes.length - i;
      for (var k = 1; valid && k <= extra; k++) {
        var next = bytes[i + k];
        if ((next & 0xc0) !== 0x80) { valid = false; break; }
        codePoint = (codePoint << 6) | (next & 0x3f);
      }
      if (!valid) throw new Error("malformed document");
      out += String.fromCodePoint(codePoint);
      i += extra + 1;
    }
    return out;
  }

  var testSeam = {
    parseWire: function (bytesBase64) {
      try {
        var bytes = base64ToBytes(bytesBase64);
        var doc = parseWire(bytes);
        return JSON.stringify({ ok: true, nodes: doc.nodes.length, edges: doc.edges.length });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    },
    buildScene: function (docJSON) {
      try {
        var doc = parseWire(utf8Encode(docJSON));
        var scene = buildScene(doc);
        return JSON.stringify({
          bounds: {
            x: scene.bounds.x, y: scene.bounds.y,
            right: scene.bounds.right, bottom: scene.bounds.bottom
          },
          nodeCount: Object.keys(scene.nodeById).length
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    },
    computeEdge: function (docJSON, fromID, toID, fromSide, toSide) {
      try {
        var doc = parseWire(utf8Encode(docJSON));
        var from = doc.nodes.find(function (n) { return n.id === fromID; });
        var to = doc.nodes.find(function (n) { return n.id === toID; });
        if (!from || !to) throw new Error("missing node");
        var geometry = computeEdgeGeometry(from, to, fromSide || null, toSide || null);
        return JSON.stringify({
          from: { x: geometry.from.x, y: geometry.from.y },
          to: { x: geometry.to.x, y: geometry.to.y },
          control1: { x: geometry.control1.x, y: geometry.control1.y },
          path: geometry.path
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    },
    layoutText: function (text, width, height) {
      try {
        var tokens = tokenizeMarkdown(text);
        var wrapped = wrapTokens(tokens, width);
        var clipped = clipLines(wrapped, height);
        return JSON.stringify({
          lines: clipped.lines.map(function (line) {
            return line.map(function (token) {
              return { type: token.type, value: token.value, href: token.href || null };
            });
          }),
          overflow: clipped.overflow
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    },
    resolveAssets: function (docJSON) {
      try {
        var doc = parseWire(utf8Encode(docJSON));
        var requests = resolveAssets(doc);
        return JSON.stringify({
          requests: requests.map(function (r) { return { role: r.role, reference: r.reference }; })
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    },
    // Edge endpoint defaults: JSON Canvas says fromEnd defaults to none,
    // toEnd defaults to arrow. Returns the APPLIED edge model (post-parse
    // defaults), not the raw wire values.
    parseEdges: function (docJSON) {
      try {
        var doc = parseWire(utf8Encode(docJSON));
        return JSON.stringify(doc.edges.map(function (e) {
          return {
            fromEnd: e.fromEnd, toEnd: e.toEnd,
            fromSide: e.fromSide, toSide: e.toSide,
            fromNode: e.fromNode, toNode: e.toNode
          };
        }));
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    },
    // Per-edge marker assignments: {edgeId: {from: markerId|null, to: markerId|null}}
    // plus the marker color info map, so tests can assert that colored edges
    // get a per-color arrowhead and default edges share the CSS-driven marker.
    edgeMarkers: function (docJSON) {
      try {
        var doc = parseWire(utf8Encode(docJSON));
        var assignment = computeEdgeMarkers(doc);
        // Make every marker present even when a color is used by no edge
        // arrow; tests assert the per-edge assignment and the marker colors.
        return JSON.stringify({ edges: assignment.edges, markers: assignment.markers });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error.message || "error") });
      }
    }
  };
  if (typeof module !== "undefined" && typeof module.exports !== "undefined") {
    module.exports = {
      parseCanvas: testSeam.parseWire,
      scene: testSeam.buildScene,
      edge: testSeam.computeEdge,
      layoutText: testSeam.layoutText,
      resolveAssets: testSeam.resolveAssets,
      parseEdges: testSeam.parseEdges,
      edgeMarkers: testSeam.edgeMarkers
    };
  }
  // Expose the seam as globals in BOTH a DOM context (window) and a plain
  // JavaScriptCore context (globalThis). The JSC harness has no window and no
  // module; without this the pure stages could not be executed by the normal
  // suite.
  if (typeof globalThis !== "undefined") {
    globalThis.__sdw_parse_canvas = testSeam.parseWire;
    globalThis.__sdw_scene = testSeam.buildScene;
    globalThis.__sdw_edge = testSeam.computeEdge;
    globalThis.__sdw_layout_text = testSeam.layoutText;
    globalThis.__sdw_resolve_assets = testSeam.resolveAssets;
    globalThis.__sdw_parse_edges = testSeam.parseEdges;
    globalThis.__sdw_edge_markers = testSeam.edgeMarkers;
  }
}());
