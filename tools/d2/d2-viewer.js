// D2 renderer package driver. Read-only: it renders the authorized source once
// and mounts the resulting static SVG.
//
// The D2 WebAssembly module runs on the main thread (the package CSP forbids
// workers). wasm_exec.js provides the Go import object; the module registers
// its API on globalThis.d2 during startup. The pinned upstream build (v0.8.2,
// pure-Go layout engines) embeds its font faces, so no font bytes are passed
// at compile time; the module measures text with and re-embeds them into the
// rendered SVG as base64 WOFF2 along with the theme stylesheet.
//
// The renderer CSP blocks inline stylesheets and inline style attributes, and
// the rendered SVG uses both for its theme colors and fonts. The mount step
// therefore moves the SVG's <style> text into a constructable stylesheet
// (CSSOM is not document parsing, so no policy is bypassed) and re-applies
// each blocked style attribute through the element's CSSStyleDeclaration. All
// bytes involved come from the pinned module output; nothing is fetched from
// any network origin.
(function () {
  "use strict";

  const requestID = "d2-initial-input";
  const renderBudgetMilliseconds = 10000;
  const bootPollMilliseconds = 50;
  const darkThemeID = 200;
  const layoutEngine = "dagre";
  const defaultLabel = "D2 diagram";

  const statusRegion = document.getElementById("status");
  const errorRegion = document.getElementById("error");
  const diagramRegion = document.getElementById("diagram");

  function showStatus(text) {
    statusRegion.textContent = text;
    statusRegion.hidden = false;
  }

  function showError(text) {
    errorRegion.textContent = text;
    errorRegion.hidden = false;
    statusRegion.hidden = true;
  }

  function fetchLocalBuffer(path) {
    return fetch(path).then((response) => {
      if (!response.ok) {
        throw new Error("The package asset " + path + " is unavailable.");
      }
      return response.arrayBuffer();
    });
  }

  function base64ToText(encoded) {
    const bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }

  // The budget is best-effort: the timer can only fire while the module yields
  // to the event loop. A non-yielding hang surfaces as an unresponsive pane,
  // which the host's failure window and safe mode already handle.
  function withBudget(promise, activity) {
    let timerID = 0;
    const budget = new Promise((resolve, reject) => {
      timerID = window.setTimeout(() => {
        reject(new Error("The diagram took too long to " + activity + "."));
      }, renderBudgetMilliseconds);
    });
    return Promise.race([promise, budget]).finally(() => window.clearTimeout(timerID));
  }

  async function bootEngine() {
    if (typeof globalThis.Go === "undefined") {
      throw new Error("The D2 runtime is unavailable.");
    }
    const go = new globalThis.Go();
    const wasmBytes = await fetchLocalBuffer("d2.wasm");
    const result = await WebAssembly.instantiate(wasmBytes, go.importObject);
    // Resolves only when the Go program exits; startup completes during the
    // synchronous prefix, so the API appears on globalThis shortly after.
    go.run(result.instance);
    let waitedMilliseconds = 0;
    while (typeof globalThis.d2 === "undefined") {
      if (waitedMilliseconds >= renderBudgetMilliseconds) {
        throw new Error("The D2 engine did not start.");
      }
      await new Promise((resolve) => window.setTimeout(resolve, bootPollMilliseconds));
      waitedMilliseconds += bootPollMilliseconds;
    }
    return globalThis.d2;
  }

  async function renderDiagram(engine, source) {
    const compileRaw = await engine.compile(
      JSON.stringify({
        fs: { index: source },
        options: { layout: layoutEngine },
      })
    );
    const compileResponse = JSON.parse(compileRaw);
    if (compileResponse.error) {
      throw new Error(compileResponse.error.message);
    }
    const board = compileResponse.data.diagram;
    const label = board && board.name && board.name !== "root" ? board.name : defaultLabel;
    const renderRaw = await engine.render(
      JSON.stringify({
        diagram: board,
        options: { darkThemeID: darkThemeID, noXMLTag: true },
      })
    );
    const renderResponse = JSON.parse(renderRaw);
    if (renderResponse.error) {
      throw new Error(renderResponse.error.message);
    }
    return { svgText: base64ToText(renderResponse.data), label: label };
  }

  // Inline presentation attributes are refused under the package CSP, so each
  // declaration is re-applied through the element's CSSStyleDeclaration.
  function applyInlinePresentations(elements) {
    for (const element of elements) {
      const declarationText = element.getAttribute("style");
      if (!declarationText) continue;
      element.removeAttribute("style");
      for (const declaration of declarationText.split(";")) {
        const separator = declaration.indexOf(":");
        if (separator === -1) continue;
        const property = declaration.slice(0, separator).trim();
        const value = declaration.slice(separator + 1).trim();
        if (property && value) element.style.setProperty(property, value);
      }
    }
  }

  function adoptStylesheet(text) {
    if (!text.trim()) return;
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(text);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  }

  function mountDiagram(svgText, label) {
    const holder = document.createElement("template");
    holder.innerHTML = svgText;
    const svg = holder.content.querySelector("svg");
    if (!svg) {
      throw new Error("The rendered diagram did not contain an SVG.");
    }
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", label);
    svg.removeAttribute("width");
    svg.removeAttribute("height");

    const stylesheetText = [...svg.querySelectorAll("style")]
      .map((node) => node.textContent)
      .join("\n");
    svg.querySelectorAll("style").forEach((node) => node.remove());

    const styledElements = [...svg.querySelectorAll("[style]")];
    diagramRegion.replaceChildren(svg);
    applyInlinePresentations(styledElements);
    adoptStylesheet(stylesheetText);
  }

  // Reads the host-authorized source exactly once through the native bridge.
  function readAuthorizedSource() {
    return new Promise((resolve, reject) => {
      const rawInput = document.documentElement.dataset.rendererInput;
      if (!rawInput) {
        reject(new Error("The authorized source is unavailable."));
        return;
      }
      let input;
      try {
        input = JSON.parse(rawInput);
      } catch (_) {
        reject(new Error("The authorized source is unavailable."));
        return;
      }
      window.addEventListener("message", function receive(event) {
        if (event.source !== window) return;
        const response = event.data && event.data.rendererBridgeResponse;
        if (typeof response !== "string") return;
        try {
          const decoded = JSON.parse(response);
          if (decoded.id !== requestID || !decoded.payload || typeof decoded.payload.bytes !== "string") {
            return;
          }
          window.removeEventListener("message", receive);
          resolve(base64ToText(decoded.payload.bytes));
        } catch (_) {
          reject(new Error("The source could not be read."));
        }
      });
      window.postMessage(
        { rendererBridge: JSON.stringify({ id: requestID, method: "input.read", input }) },
        "*"
      );
    });
  }

  async function run() {
    showStatus("Starting the D2 engine.");
    const [engine, source] = await Promise.all([bootEngine(), readAuthorizedSource()]);
    showStatus("Rendering the diagram.");
    const rendered = await renderDiagram(engine, source);
    mountDiagram(rendered.svgText, rendered.label);
    statusRegion.hidden = true;
  }

  withBudget(run(), "render").catch((error) => {
    showError(
      error && error.message ? error.message : "The diagram could not be rendered."
    );
  });
})();
