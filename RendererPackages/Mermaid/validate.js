// Mermaid fence-syntax validation contract (manifest revision 3).
//
// The host's generic FenceSyntaxValidator evaluates the declared engine
// asset (mermaid.min.js) and then this wrapper in a bare JavaScriptCore
// context, and calls the declared entry function with the fence text. This
// file owns all mermaid-specific validation knowledge:
//
//   1. A minimal DOM/timer polyfill, installed BEFORE the engine evaluates.
//      mermaid v11 bundles DOMPurify, whose factory returns undefined
//      without a DOM and then crashes on addHook; the stubs below are
//      sufficient for the engine to load and for mermaid.parse() to run.
//   2. The entry function itself: it drives mermaid.parse(text), attaches
//      Promise callbacks that mutate a holder object, and returns the
//      holder. The host flushes the JSC microtask queue after the call,
//      then reads { done, isValid, diagramType, errors }.
//
// The validate/render contract is one engine: anything that renders also
// validates, and vice versa, with no version skew.
(function () {
  "use strict";

  // JSC has no timer functions by default — install no-op stubs before
  // anything else can reference them.
  globalThis.__timers = globalThis.__timers || { nextId: 1 };
  globalThis.setTimeout = function (fn) {
    var id = globalThis.__timers.nextId++;
    return id;
  };
  globalThis.clearTimeout = function (id) {};
  globalThis.setInterval = function (fn) {
    var id = globalThis.__timers.nextId++;
    return id;
  };
  globalThis.clearInterval = function (id) {};
  // structuredClone — needed by some diagram types (e.g. pie). A JSON
  // round-trip is sufficient for the engine's internal use.
  if (typeof globalThis.structuredClone !== "function") {
    globalThis.structuredClone = function (o) {
      return JSON.parse(JSON.stringify(o));
    };
  }

  // Minimal DOM/timer/window polyfill sufficient for mermaid.min.js to load
  // and run mermaid.parse() in a bare JSContext.
  function Noop() {}
  function makeNode(tag) {
    var node = {
      tagName: (tag || "").toUpperCase(),
      nodeName: (tag || "").toUpperCase(),
      nodeType: 1,
      children: [],
      childNodes: [],
      attributes: {},
      style: {},
      classList: {
        add: Noop,
        remove: Noop,
        contains: function () { return false; },
        toggle: Noop
      },
      getAttribute: function (k) {
        return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null;
      },
      setAttribute: function (k, v) { this.attributes[k] = String(v); },
      removeAttribute: function (k) { delete this.attributes[k]; },
      hasAttribute: function (k) {
        return Object.prototype.hasOwnProperty.call(this.attributes, k);
      },
      appendChild: function (c) {
        this.children.push(c);
        this.childNodes.push(c);
        c.parentNode = this;
        return c;
      },
      removeChild: function (c) {
        var i = this.children.indexOf(c);
        if (i >= 0) {
          this.children.splice(i, 1);
          this.childNodes.splice(i, 1);
        }
        return c;
      },
      insertBefore: function (c, r) { this.appendChild(c); return c; },
      replaceChild: function (n, o) { return o; },
      cloneNode: function () { return makeNode(this.tagName); },
      querySelectorAll: function () { return []; },
      querySelector: function () { return null; },
      addEventListener: Noop,
      removeEventListener: Noop,
      textContent: "",
      innerHTML: "",
      outerHTML: "",
      firstChild: null,
      lastChild: null,
      parentNode: null,
      ownerDocument: null
    };
    return node;
  }

  var emptyDoc = {
    nodeType: 9,
    documentElement: makeNode("html"),
    head: makeNode("head"),
    body: makeNode("body"),
    createElement: makeNode,
    createElementNS: function (ns, tag) { return makeNode(tag); },
    createTextNode: function (t) {
      return { nodeType: 3, nodeValue: String(t), textContent: String(t) };
    },
    createComment: function (t) {
      return { nodeType: 8, nodeValue: String(t) };
    },
    createDocumentFragment: function () { return makeNode("fragment"); },
    getElementById: function () { return null; },
    getElementsByTagName: function () { return []; },
    getElementsByClassName: function () { return []; },
    querySelector: function () { return null; },
    querySelectorAll: function () { return []; },
    addEventListener: Noop,
    removeEventListener: Noop,
    implementation: {
      createHTMLDocument: function () { return emptyDoc; },
      createDocument: function () { return emptyDoc; },
      hasFeature: function () { return true; }
    },
    defaultView: null
  };
  emptyDoc.defaultView = null;
  var win = {
    document: emptyDoc,
    Document: Noop,
    Node: Noop,
    Element: Noop,
    addEventListener: Noop,
    removeEventListener: Noop,
    navigator: { userAgent: "jsc-polyfill" },
    location: { href: "about:blank", protocol: "about:" },
    matchMedia: function () {
      return {
        matches: false,
        addListener: Noop,
        removeListener: Noop,
        addEventListener: Noop,
        removeEventListener: Noop
      };
    },
    requestAnimationFrame: function (cb) {
      return setTimeout(function () { cb(Date.now()); }, 0);
    },
    cancelAnimationFrame: function () {},
    getComputedStyle: function () {
      return { getPropertyValue: function () { return ""; } };
    },
    TextEncoder: function () {
      this.encode = function (s) {
        var bytes = [];
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c < 0x80) bytes.push(c);
          else if (c < 0x800) { bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
          else {
            bytes.push(
              0xe0 | (c >> 12),
              0x80 | ((c >> 6) & 0x3f),
              0x80 | (c & 0x3f)
            );
          }
        }
        return { length: bytes.length, buffer: new Uint8Array(bytes).buffer };
      };
    },
    TextDecoder: function () { this.decode = function () { return ""; }; },
    setTimeout: setTimeout,
    clearTimeout: clearTimeout,
    setInterval: setInterval,
    clearInterval: clearInterval,
    Map: Map,
    Set: Set,
    Promise: Promise,
    Uint8Array: Uint8Array
  };
  emptyDoc.defaultView = win;
  globalThis.window = win;
  globalThis.document = emptyDoc;
  globalThis.TextEncoder = win.TextEncoder;
  globalThis.TextDecoder = win.TextDecoder;
  globalThis.navigator = win.navigator;
  globalThis.location = win.location;
  globalThis.requestAnimationFrame = win.requestAnimationFrame;
  globalThis.cancelAnimationFrame = win.cancelAnimationFrame;
  globalThis.matchMedia = win.matchMedia;
  globalThis.self = win;

  // The entry function. Returns a holder object; the host calls it, flushes
  // the microtask queue, then reads the holder back. The try/catch is
  // defensive against engine builds that throw synchronously (verified
  // v11.16.0 always returns a Promise).
  globalThis.__sdw_validate_fence = function (text) {
    var r = { done: false, isValid: false, diagramType: null, errors: [] };
    try {
      var firstLine = String(text || "").split(/\r?\n/)[0].trim();
      var m = firstLine.match(/^(\w+)/);
      if (m) r.diagramType = m[1];
      var p = mermaid.parse(text);
      if (p && typeof p.then === "function") {
        p.then(function () {
          r.done = true;
          r.isValid = true;
        }).catch(function (e) {
          r.done = true;
          r.isValid = false;
          var msg = e && e.message ? e.message : String(e);
          var lineMatch = String(msg).match(/line\s+(\d+)/i);
          var line = lineMatch ? parseInt(lineMatch[1], 10) : null;
          r.errors.push({
            line: line,
            code: "PARSE_ERROR",
            message: String(msg).split("\n")[0]
          });
        });
      } else {
        // Not a Promise (defensive) — treat as success.
        r.done = true;
        r.isValid = true;
      }
    } catch (e) {
      r.done = true;
      r.isValid = false;
      var msg = e && e.message ? e.message : String(e);
      var lineMatch = String(msg).match(/line\s+(\d+)/i);
      var line = lineMatch ? parseInt(lineMatch[1], 10) : null;
      r.errors.push({
        line: line,
        code: "PARSE_ERROR",
        message: String(msg).split("\n")[0]
      });
    }
    return r;
  };
})();
