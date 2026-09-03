// SVG renderer package driver. Read-only: it loads the authorized source once
// and mounts the exact bytes as an inert image.
//
// The SVG document is loaded through an <img> element, which puts WebKit in
// its restricted SVG image mode: script never runs, event handlers never
// bind, and external references never load. The bytes are transported as a
// base64 data: URL so no intermediate copy can re-parse the document; the
// host CSP admits data: in img-src for exactly this inert surface.
//
// Appearance follows the system through CSS Canvas colors, and the zoom
// affordances are the host page-zoom shortcuts, so the driver owns no
// appearance state of its own.
(function () {
  "use strict";

  const requestID = "svg-initial-input";
  const loadBudgetMilliseconds = 10000;

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
          resolve(decoded.payload.bytes);
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

  // Mounts the exact bytes as an inert image. The base64 payload is never
  // decoded into markup; WebKit's image mode is the security boundary.
  function mountImage(base64Bytes) {
    const image = document.createElement("img");
    image.alt = "SVG diagram";
    image.decoding = "async";
    image.src = "data:image/svg+xml;base64," + base64Bytes;
    const loaded = new Promise((resolve, reject) => {
      image.addEventListener("load", () => resolve(), { once: true });
      image.addEventListener("error", () => reject(new Error("The SVG document could not be displayed.")), { once: true });
    });
    diagramRegion.replaceChildren(image);
    return loaded;
  }

  async function run() {
    showStatus("Loading the SVG document.");
    const base64Bytes = await readAuthorizedSource();
    await mountImage(base64Bytes);
    statusRegion.hidden = true;
  }

  const budget = new Promise((resolve, reject) => {
    window.setTimeout(() => {
      reject(new Error("The SVG document took too long to load."));
    }, loadBudgetMilliseconds);
  });

  Promise.race([run(), budget]).catch((error) => {
    showError(
      error && error.message ? error.message : "The SVG document could not be displayed."
    );
  });
})();
