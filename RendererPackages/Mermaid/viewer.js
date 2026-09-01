// Mermaid renderer package driver. Read-only: it renders the authorized
// source once and mounts the resulting static SVG.
//
// The pinned mermaid engine (mermaid.min.js) is a UMD/IIFE bundle loaded
// before this file; it registers globalThis.mermaid. The engine is
// initialized with startOnLoad disabled and the strict security level, then
// asked to render the source into SVG bytes inside this document.
//
// Appearance follows the system: the theme is chosen from the
// prefers-color-scheme media query and the diagram is re-rendered when the
// appearance changes, so the pane keeps up with light/dark transitions
// without any host-side re-render plumbing.
(function () {
  "use strict";

  const requestID = "mermaid-initial-input";
  const renderBudgetMilliseconds = 10000;

  const statusRegion = document.getElementById("status");
  const errorRegion = document.getElementById("error");
  const diagramRegion = document.getElementById("diagram");

  function showStatus(text) {
    statusRegion.textContent = text;
    statusRegion.hidden = false;
  }

  function showError(text) {
    // The error region carries the failure summary only. Source bytes are
    // never echoed into the document, so a parse failure cannot turn author
    // content into markup.
    errorRegion.textContent = text;
    errorRegion.hidden = false;
    statusRegion.hidden = true;
  }

  function currentTheme() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "default";
  }

  // The budget is best-effort: the timer can only fire while the engine yields
  // to the event loop. A non-yielding hang surfaces as an unresponsive pane,
  // which the host's failure window and safe mode already handle.
  function withBudget(promise, activity) {
    let timerID = 0;
    const budget = new Promise((resolve, reject) => {
      timerID = window.setTimeout(() => {
        reject(new Error("The diagram took too long to " + activity + "."));
      }, renderBudgetMilliseconds);
    });
    return Promise.race([promise, budget]).finally(() =>
      window.clearTimeout(timerID)
    );
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
          const bytes = Uint8Array.from(atob(decoded.payload.bytes), (character) =>
            character.charCodeAt(0)
          );
          resolve(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
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

  async function renderInto(element, engine, source, theme) {
    const { svg } = await engine.render("diagram-render", source, {
      theme: theme,
      securityLevel: "strict",
    });
    const holder = document.createElement("template");
    holder.innerHTML = svg;
    const mounted = holder.content.firstElementChild;
    if (!mounted || mounted.tagName.toLowerCase() !== "svg") {
      throw new Error("The rendered diagram did not contain an SVG.");
    }
    mounted.setAttribute("role", "img");
    mounted.setAttribute("aria-label", "Mermaid diagram");
    element.replaceChildren(mounted);
  }

  async function run() {
    if (typeof globalThis.mermaid === "undefined") {
      throw new Error("The mermaid engine is unavailable.");
    }
    const engine = globalThis.mermaid;
    engine.initialize({ startOnLoad: false, securityLevel: "strict" });
    showStatus("Rendering the diagram.");
    const source = await readAuthorizedSource();
    await renderInto(diagramRegion, engine, source, currentTheme());

    // Keep the pane in step with system appearance changes. The host has no
    // hand in this; the driver owns its theme lifecycle.
    const appearance = window.matchMedia("(prefers-color-scheme: dark)");
    appearance.addEventListener("change", () => {
      renderInto(diagramRegion, engine, source, currentTheme()).catch(() => {
        // A theme re-render failure leaves the last successful diagram in
        // place; the original render already proved the source valid.
      });
    });
    statusRegion.hidden = true;
  }

  withBudget(run(), "render").catch((error) => {
    showError(
      error && error.message ? error.message : "The diagram could not be rendered."
    );
  });
})();
