/**
 * jsonrender-form.js — Hand-written vanilla-JS form renderer for Self Driving Wiki.
 *
 * Renders the json-render form-primitives spec subset ({ root, elements, state? })
 * into HTML form inputs inside a WKWebView. No React, no npm, no build step.
 *
 * Vendoring provenance: hand-written for this project (not an upstream npm package).
 * Based on the json-render spec format from https://github.com/vercel-labs/json-render
 * (packages/core/src/types.ts, actions.ts, props.ts). Re-vendor: copy this file
 * into Sources/WikiFS/ and build.sh copies it to the app bundle's Resources/.
 *
 * Public API: window.WikiJSONRender = { applyBase64, getState }
 *   applyBase64(b64): decode base64 spec, JSON.parse, render into #root
 *   getState(): return current form state as JSON string
 *
 * Spec format:
 *   { root: "form",
 *     elements: {
 *       "form":      { type: "Stack", children: ["name", "pass", "add"] },
 *       "name":      { type: "TextField",   props: { label, value: { $bindState: "/form/name" } } },
 *       "pass":      { type: "PasswordField", props: { label, value: { $bindState: "/form/pass" } } },
 *       "add":       { type: "Button", props: { label: "Add" },
 *                      on: { press: { action: "addSource",
 *                        params: { name: { $state: "/form/name" }, pass: { $state: "/form/pass" } } } } }
 *     },
 *     state: {} }
 */
(function () {
  'use strict';

  var state = {};
  var spec = null;
  var rootEl = null;

  // ── JSON Pointer (RFC 6901) helpers ──────────────────────────────────────

  function decodeSeg(s) { return s.replace(/~1/g, '/').replace(/~0/g, '~'); }

  function getByPath(obj, path) {
    if (!path || path === '/') return obj;
    var segs = path.charAt(0) === '/' ? path.slice(1).split('/') : path.split('/');
    var cur = obj;
    for (var i = 0; i < segs.length; i++) {
      if (cur == null) return undefined;
      cur = cur[decodeSeg(segs[i])];
    }
    return cur;
  }

  function setByPath(obj, path, value) {
    if (!path || path === '/') return;
    var segs = path.charAt(0) === '/' ? path.slice(1).split('/') : path.split('/');
    var cur = obj;
    for (var i = 0; i < segs.length - 1; i++) {
      var s = decodeSeg(segs[i]);
      if (cur[s] == null || typeof cur[s] !== 'object') cur[s] = {};
      cur = cur[s];
    }
    cur[decodeSeg(segs[segs.length - 1])] = value;
  }

  // ── Prop expression resolution (matches upstream resolveDynamicValue) ──

  function isStateExpr(v) {
    return v != null && typeof v === 'object' && '$state' in v;
  }
  function isBindStateExpr(v) {
    return v != null && typeof v === 'object' && '$bindState' in v;
  }

  function resolveProp(v) {
    if (isStateExpr(v)) return getByPath(state, v.$state);
    if (isBindStateExpr(v)) return getByPath(state, v.$bindState);
    if (v != null && typeof v === 'object' && !Array.isArray(v)) {
      var out = {};
      for (var k in v) out[k] = resolveProp(v[k]);
      return out;
    }
    if (Array.isArray(v)) return v.map(resolveProp);
    return v;
  }

  function resolveParams(params) {
    if (!params) return {};
    var out = {};
    for (var k in params) out[k] = resolveProp(params[k]);
    return out;
  }

  // ── Action emission ─────────────────────────────────────────────────────

  function emitAction(action, params) {
    var msg = { action: action, params: params };
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.addAction) {
        window.webkit.messageHandlers.addAction.postMessage(msg);
      }
    } catch (e) { /* message handler not registered (test context) */ }
  }

  function getActionBinding(element) {
    if (element.on && element.on.press) {
      return Array.isArray(element.on.press) ? element.on.press[0] : element.on.press;
    }
    // Simplified convenience: props.action + props.actionParams
    if (element.props && element.props.action) {
      return { action: element.props.action, params: element.props.actionParams || {} };
    }
    return null;
  }

  // ── DOM helpers ──────────────────────────────────────────────────────────

  function el(tag, attrs) {
    var node = document.createElement(tag);
    if (attrs) for (var k in attrs) {
      if (k === 'class') node.className = attrs[k];
      else if (k === 'text') node.textContent = attrs[k];
      else node.setAttribute(k, attrs[k]);
    }
    return node;
  }

  function wrapField(elementId, label, inputNode, checkboxStyle) {
    var wrap = el('div', { class: 'wiki-field', 'data-wiki-render-id': elementId });
    if (checkboxStyle) {
      var lab = el('label');
      inputNode.id = 'wr-' + elementId;
      lab.appendChild(inputNode);
      if (label) lab.appendChild(document.createTextNode(' ' + label));
      wrap.appendChild(lab);
    } else {
      if (label) wrap.appendChild(el('label', { for: 'wr-' + elementId, text: label }));
      if (inputNode) {
        inputNode.id = 'wr-' + elementId;
        wrap.appendChild(inputNode);
      }
    }
    return wrap;
  }

  // ── Component renderers ────────────────────────────────────────────────

  var renderers = {
    Stack: function (id, elem, container) {
      var div = el('div', { class: 'wiki-render-stack', 'data-wiki-render-id': id });
      if (elem.props && elem.props.direction === 'horizontal')
        div.className = 'wiki-render-stack wiki-render-stack-h';
      (elem.children || []).forEach(function (cid) {
        var child = spec.elements[cid];
        if (child) renderElement(cid, child, div);
      });
      container.appendChild(div);
    },

    Text: function (id, elem, container) {
      container.appendChild(el('p', {
        class: 'wiki-text', 'data-wiki-render-id': id,
        text: resolveProp(elem.props && elem.props.content) || ''
      }));
    },

    TextField: function (id, elem, container) {
      var p = elem.props || {};
      var input = el('input', { type: 'text' });
      if (p.placeholder) input.placeholder = resolveProp(p.placeholder);
      var bp = isBindStateExpr(p.value) ? p.value.$bindState : null;
      if (bp) {
        var v = getByPath(state, bp);
        if (v != null) input.value = String(v);
        input.addEventListener('input', function (e) { setByPath(state, bp, e.target.value); });
      } else if (p.value != null) { input.value = String(resolveProp(p.value)); }
      container.appendChild(wrapField(id, resolveProp(p.label), input));
    },

    PasswordField: function (id, elem, container) {
      var p = elem.props || {};
      var input = el('input', { type: 'password' });
      if (p.placeholder) input.placeholder = resolveProp(p.placeholder);
      var bp = isBindStateExpr(p.value) ? p.value.$bindState : null;
      if (bp) {
        var v = getByPath(state, bp);
        if (v != null) input.value = String(v);
        input.addEventListener('input', function (e) { setByPath(state, bp, e.target.value); });
      }
      container.appendChild(wrapField(id, resolveProp(p.label), input));
    },

    NumberField: function (id, elem, container) {
      var p = elem.props || {};
      var input = el('input', { type: 'number' });
      if (p.placeholder) input.placeholder = resolveProp(p.placeholder);
      if (p.min != null) input.min = String(resolveProp(p.min));
      if (p.max != null) input.max = String(resolveProp(p.max));
      var bp = isBindStateExpr(p.value) ? p.value.$bindState : null;
      if (bp) {
        var v = getByPath(state, bp);
        if (v != null) input.value = String(v);
        input.addEventListener('input', function (e) {
          setByPath(state, bp, e.target.value === '' ? null : Number(e.target.value));
        });
      }
      container.appendChild(wrapField(id, resolveProp(p.label), input));
    },

    SelectField: function (id, elem, container) {
      var p = elem.props || {};
      var select = el('select');
      var opts = resolveProp(p.options) || [];
      opts.forEach(function (opt) {
        var val, lbl;
        if (typeof opt === 'string') { val = opt; lbl = opt; }
        else { val = opt.value; lbl = opt.label || opt.value; }
        select.appendChild(el('option', { value: val, text: lbl }));
      });
      var bp = isBindStateExpr(p.value) ? p.value.$bindState : null;
      if (bp) {
        var v = getByPath(state, bp);
        if (v != null) select.value = String(v);
        select.addEventListener('change', function (e) { setByPath(state, bp, e.target.value); });
      }
      container.appendChild(wrapField(id, resolveProp(p.label), select));
    },

    Checkbox: function (id, elem, container) {
      var p = elem.props || {};
      var input = el('input', { type: 'checkbox' });
      var bp = isBindStateExpr(p.value) ? p.value.$bindState : null;
      if (bp) {
        if (getByPath(state, bp) === true) input.checked = true;
        input.addEventListener('change', function (e) { setByPath(state, bp, e.target.checked); });
      }
      container.appendChild(wrapField(id, resolveProp(p.label), input, true));
    },

    DateRange: function (id, elem, container) {
      var p = elem.props || {};
      var wrap = el('div', { class: 'wiki-field wiki-daterange', 'data-wiki-render-id': id });
      if (p.label) wrap.appendChild(el('label', { text: resolveProp(p.label) }));
      var inputs = el('div', { class: 'wiki-daterange-inputs' });
      var start = el('input', { type: 'date' });
      var end = el('input', { type: 'date' });
      start.id = 'wr-' + id + '-start';
      end.id = 'wr-' + id + '-end';
      var bpS = isBindStateExpr(p.start) ? p.start.$bindState : null;
      var bpE = isBindStateExpr(p.end) ? p.end.$bindState : null;
      if (bpS) {
        var sv = getByPath(state, bpS);
        if (sv != null) start.value = String(sv);
        start.addEventListener('input', function (e) { setByPath(state, bpS, e.target.value); });
      }
      if (bpE) {
        var ev = getByPath(state, bpE);
        if (ev != null) end.value = String(ev);
        end.addEventListener('input', function (e) { setByPath(state, bpE, e.target.value); });
      }
      inputs.appendChild(start);
      inputs.appendChild(end);
      wrap.appendChild(inputs);
      container.appendChild(wrap);
    },

    FilePicker: function (id, elem, container) {
      var p = elem.props || {};
      var input = el('input', { type: 'file' });
      var bp = isBindStateExpr(p.value) ? p.value.$bindState : null;
      if (bp) {
        input.addEventListener('change', function (e) {
          var f = e.target.files && e.target.files[0];
          setByPath(state, bp, f ? f.name : null);
        });
      }
      container.appendChild(wrapField(id, resolveProp(p.label), input));
    },

    Button: function (id, elem, container) {
      var p = elem.props || {};
      var btn = el('button', {
        class: 'wiki-btn', 'data-wiki-render-id': id,
        text: resolveProp(p.label) || 'Button'
      });
      btn.addEventListener('click', function () {
        var binding = getActionBinding(elem);
        if (binding) emitAction(binding.action, resolveParams(binding.params));
      });
      container.appendChild(btn);
    }
  };

  function renderElement(id, elem, container) {
    var r = renderers[elem.type];
    if (r) r(id, elem, container);
    else container.appendChild(el('div', {
      class: 'wiki-unknown', 'data-wiki-render-id': id,
      text: '[Unknown: ' + elem.type + ']'
    }));
  }

  function render(specObj) {
    spec = specObj;
    state = spec.state ? JSON.parse(JSON.stringify(spec.state)) : {};
    if (!rootEl) rootEl = document.getElementById('root');
    if (!rootEl) return;
    rootEl.innerHTML = '';
    var rootElem = spec.elements[spec.root];
    if (rootElem) renderElement(spec.root, rootElem, rootEl);
  }

  // ── Public API ───────────────────────────────────────────────────────────

  window.WikiJSONRender = {
    applyBase64: function (b64) {
      try {
        var binary = atob(b64);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        var json = new TextDecoder().decode(bytes);
        render(JSON.parse(json));
      } catch (e) {
        console.error('WikiJSONRender.applyBase64 error:', e);
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.error)
            window.webkit.messageHandlers.error.postMessage({ message: String(e) });
        } catch (_) { /* ignore */ }
      }
    },
    getState: function () { return JSON.stringify(state); }
  };
})();
