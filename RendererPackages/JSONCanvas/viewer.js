(function () {
  "use strict";

  var hasDOM = typeof document !== "undefined" && typeof window !== "undefined";
  var viewer = hasDOM ? document.getElementById("viewer") : null;
  var namespace = "http://www.w3.org/2000/svg";
  var requestID = "json-canvas-initial-input";
  var minimumScale = 0.25;
  var maximumScale = 4;
  var zoomFactor = 1.1;
  var keyboardPanStep = 32;
  var maximumInputBytes = 48000;
  var maximumNodeCount = 512;
  var maximumEdgeCount = 1024;
  var maximumIdentifierLength = 128;
  var maximumTextLength = 8192;
  var maximumCoordinateMagnitude = 1000000;
  var presetColors = { "1": "#e03131", "2": "#f08c00", "3": "#f5c415", "4": "#2b8a3e", "5": "#0c8599", "6": "#7048e8" };

  function makeSVG(name, attributes) {
    var node = document.createElementNS(namespace, name);
    Object.keys(attributes || {}).forEach(function (key) { node.setAttribute(key, String(attributes[key])); });
    return node;
  }

  function byteStringToText(encoded) {
    var bytes = Uint8Array.from(atob(encoded), function (character) { return character.charCodeAt(0); });
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
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

  // Bounded validator before any allocation: node/edge counts, identifiers,
  // text lengths, finite geometry, known endpoints, colors, and link syntax.
  function parseCanvas(bytes) {
    if (bytes.byteLength > maximumInputBytes) throw new Error("oversized input");
    var text;
    try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch (_) { throw new Error("malformed document"); }
    var value;
    try { value = JSON.parse(text); }
    catch (_) { throw new Error("malformed document"); }
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("malformed document");
    if (!Array.isArray(value.nodes)) throw new Error("malformed document");
    if (!Array.isArray(value.edges)) throw new Error("malformed document");
    if (value.nodes.length > maximumNodeCount) throw new Error("too many nodes");
    if (value.edges.length > maximumEdgeCount) throw new Error("too many edges");

    var seenNodeIDs = Object.create(null);
    var nodes = value.nodes.map(function (wire, index) {
      if (wire === null || typeof wire !== "object") throw new Error("malformed document");
      if (typeof wire.id !== "string" || wire.id.length === 0 || wire.id.length > maximumIdentifierLength) throw new Error("invalid node id");
      if (Object.prototype.hasOwnProperty.call(seenNodeIDs, wire.id)) throw new Error("duplicate node id");
      seenNodeIDs[wire.id] = true;
      var x = wire.x, y = wire.y, width = wire.width, height = wire.height;
      if (!isFiniteNumber(x) || !isFiniteNumber(y) || !isFiniteNumber(width) || !isFiniteNumber(height)) throw new Error("invalid geometry");
      if (Math.abs(x) > maximumCoordinateMagnitude || Math.abs(y) > maximumCoordinateMagnitude ||
          width <= 0 || height <= 0 || width > maximumCoordinateMagnitude || height > maximumCoordinateMagnitude) throw new Error("invalid geometry");
      if (wire.color !== undefined && !isValidColor(wire.color)) throw new Error("invalid color");
      var textValue = "";
      var type = wire.type;
      var file = null, subpath = null, url = null;
      if (type === "text") {
        if (typeof wire.text !== "string") throw new Error("malformed document");
        textValue = wire.text;
      } else if (type === "file") {
        if (!isValidFileReference(wire.file)) throw new Error("invalid internal link");
        file = wire.file;
        if (wire.subpath !== undefined) {
          if (typeof wire.subpath !== "string" || wire.subpath.length === 0 || wire.subpath.length > maximumTextLength ||
              wire.subpath.charAt(0) !== "#" || /[?#%]/.test(wire.subpath) || /[\u0000-\u001f\u007f]/.test(wire.subpath)) throw new Error("invalid internal link");
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
        // Groups render as bounded atomic boxes: a label and an optional
        // CSS color background. The background must be a preset/hex color;
        // raw file names are not treated as colors.
        if (wire.label !== undefined && (typeof wire.label !== "string" || wire.label.length > maximumTextLength)) {
          throw new Error("text too large");
        }
        textValue = typeof wire.label === "string" ? wire.label : "";
        if (wire.background !== undefined && !isValidColor(wire.background)) {
          throw new Error("invalid color");
        }
        if (wire.backgroundStyle !== undefined && !(wire.backgroundStyle === "cover" || wire.backgroundStyle === "ratio" || wire.backgroundStyle === "repeat")) {
          throw new Error("malformed document");
        }
      } else {
        throw new Error("unsupported node type");
      }
      if (textValue.length > maximumTextLength) throw new Error("text too large");
      return { id: wire.id, type: type, x: x, y: y, width: width, height: height, text: textValue, color: wire.color, file: file, subpath: subpath, url: url, background: wire.background, backgroundStyle: wire.backgroundStyle, label: type === "group" ? (typeof wire.label === "string" ? wire.label : "") : null };
    });

    var seenEdgeIDs = Object.create(null);
    var edges = value.edges.map(function (wire) {
      if (wire === null || typeof wire !== "object") throw new Error("malformed document");
      if (typeof wire.id !== "string" || wire.id.length === 0 || wire.id.length > maximumIdentifierLength) throw new Error("duplicate edge id");
      if (Object.prototype.hasOwnProperty.call(seenEdgeIDs, wire.id)) throw new Error("duplicate edge id");
      seenEdgeIDs[wire.id] = true;
      if (typeof wire.fromNode !== "string" || typeof wire.toNode !== "string" ||
          !Object.prototype.hasOwnProperty.call(seenNodeIDs, wire.fromNode) || !Object.prototype.hasOwnProperty.call(seenNodeIDs, wire.toNode)) {
        throw new Error("unknown edge endpoint");
      }
      if (wire.color !== undefined && !isValidColor(wire.color)) throw new Error("invalid color");
      if (wire.label !== undefined && (typeof wire.label !== "string" || wire.label.length > maximumTextLength)) throw new Error("text too large");
      return { id: wire.id, fromNode: wire.fromNode, toNode: wire.toNode, color: wire.color, label: wire.label };
    });

    return { nodes: nodes, edges: edges };
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

  function render(documentValue) {
    if (!Array.isArray(documentValue.nodes) || !Array.isArray(documentValue.edges)) {
      showMessage("This canvas is not a supported JSON Canvas document.");
      return;
    }
    var svg = makeSVG("svg", { class: "scene", role: "group", "aria-label": "Read-only JSON Canvas, use arrow keys to pan and plus or minus to zoom" });
    var defs = makeSVG("defs");
    var marker = makeSVG("marker", { id: "sdw-arrowhead", markerWidth: "8", markerHeight: "8", refX: "6", refY: "3", orient: "auto", markerUnits: "strokeWidth" });
    var arrow = makeSVG("path", { d: "M0,0 L6,3 L0,6 z", class: "edge-arrow", fill: "currentColor" });
    marker.append(arrow);
    defs.append(marker);
    var scene = makeSVG("g");
    // Deterministic z-order: render nodes in array order (later nodes on top),
    // then edges beneath nodes but in array order; native stores reversed top
    // hit order while preserving input-order outline, so the SVG keeps edges
    // under nodes and nodes under later nodes.
    var nodeById = Object.create(null);
    documentValue.nodes.forEach(function (node) { nodeById[node.id] = node; });
    documentValue.edges.forEach(function (edge) {
      var from = nodeById[edge.fromNode], to = nodeById[edge.toNode];
      if (!from || !to) return;
      var line = makeSVG("line", { class: "edge", x1: from.x + from.width / 2, y1: from.y + from.height / 2, x2: to.x + to.width / 2, y2: to.y + to.height / 2, stroke: edge.color ? edgeColor(edge.color) : "currentColor", "marker-end": "url(#sdw-arrowhead)" });
      if (edge.label) {
        var labelX = (from.x + from.width / 2 + to.x + to.width / 2) / 2;
        var labelY = (from.y + from.height / 2 + to.y + to.height / 2) / 2 - 6;
        var labelNode = makeSVG("text", { class: "edge-label", x: labelX, y: labelY });
        labelNode.textContent = edge.label;
        scene.append(line, labelNode);
      } else {
        scene.append(line);
      }
    });
    documentValue.nodes.forEach(function (node) {
      var href = externalHref(node);
      var wrapper = href
        ? makeSVG("a", { href: href, class: "node-anchor" })
        : makeSVG("g", { class: "node-wrapper" });
      var rect = makeSVG("rect", { class: "node", x: node.x, y: node.y, width: node.width, height: node.height, fill: "transparent", stroke: nodeStroke(node) });
      wrapper.append(rect);
      if (node.type === "text") {
        var textNode = makeSVG("text", { class: "node-text", x: node.x + 8, y: node.y + 20 });
        textNode.textContent = node.text;
        wrapper.append(textNode);
      }
      if (node.type === "group") {
        // Group background fill from the bounded CSS color; the label is the
        // group's text. The group box is atomic and read-only.
        if (node.background !== undefined) {
          rect.setAttribute("fill", edgeColor(node.background));
        }
        var groupLabel = makeSVG("text", { class: "node-label", x: node.x + 8, y: node.y + 20 });
        groupLabel.textContent = node.label || "";
        wrapper.append(groupLabel);
      } else if (node.type === "file" || node.type === "link") {
        var label = makeSVG("text", { class: "node-label", x: node.x + 8, y: node.y + 20 });
        label.textContent = node.text;
        wrapper.append(label);
      }
      var target = nodeTarget(node);
      if (target) {
        wrapper.setAttribute("data-renderer-host-navigation", JSON.stringify(target));
        wrapper.setAttribute("tabindex", "0");
        wrapper.setAttribute("role", "link");
        wrapper.setAttribute("aria-label", node.text || node.label || "Open canvas node");
      }
      if (href) {
        wrapper.setAttribute("aria-label", node.text || "Open external link");
      }
      scene.append(wrapper);
    });
    svg.append(defs, scene);
    viewer.replaceChildren(svg);

    var bounds = canvasBounds(documentValue.nodes);
    var view = { scale: 1, x: -bounds.x + 24, y: -bounds.y + 24 };
    function applyView() { scene.setAttribute("transform", "translate(" + view.x + " " + view.y + ") scale(" + view.scale + ")"); }
    function setScale(next) { view.scale = Math.min(maximumScale, Math.max(minimumScale, next)); }
    applyView();

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
    viewer.addEventListener("keydown", function (event) {
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

  function canvasBounds(nodes) {
    if (nodes.length === 0) return { x: 0, y: 0, width: 1, height: 1 };
    var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
    nodes.forEach(function (node) {
      if (node.x < left) left = node.x;
      if (node.y < top) top = node.y;
      if (node.x + node.width > right) right = node.x + node.width;
      if (node.y + node.height > bottom) bottom = node.y + node.height;
    });
    return { x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) };
  }

  function edgeColor(color) { return isValidColor(color) ? (presetColors[color] || color) : "currentColor"; }

  function nodeStroke(node) {
    if (node.color !== undefined) return edgeColor(node.color);
    return "currentColor";
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
        render(JSON.parse(byteStringToText(decoded.payload.bytes)));
      } catch (_) {
        showMessage("This canvas could not be read.");
      }
    });
    window.postMessage({ rendererBridge: JSON.stringify({ id: requestID, method: "input.read", input: input }) }, "*");
  }

  if (hasDOM) {
    readAuthorizedInput();
  }

  // Production-inert test seam: returns {ok, reason} so the normal suite can
  // execute the exact parser entry used by this viewer. No page authority is
  // exposed, and it is not called from production path.
  var parseCanvasSeam = function (bytesBase64) {
    try {
      var bytes = Uint8Array.from(atob(bytesBase64), function (character) { return character.charCodeAt(0); });
      var parsed = parseCanvas(bytes);
      return JSON.stringify({ ok: true, nodes: parsed.nodes.length, edges: parsed.edges.length });
    } catch (error) {
      return JSON.stringify({ ok: false, reason: String(error.message || "error") });
    }
  };
  if (typeof module !== "undefined" && typeof module.exports !== "undefined") {
    module.exports = { parseCanvas: parseCanvasSeam };
  } else if (hasDOM) {
    window.__sdw_parse_canvas = parseCanvasSeam;
  }
}());
