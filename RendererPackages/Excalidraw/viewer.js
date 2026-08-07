(function () {
  "use strict";

  const viewer = document.getElementById("viewer");
  const namespace = "http://www.w3.org/2000/svg";
  const requestID = "excalidraw-initial-input";
  const minimumScale = 0.25;
  const maximumScale = 4;
  const zoomFactor = 1.1;
  const keyboardPanStep = 32;

  function makeSVG(name, attributes) {
    const node = document.createElementNS(namespace, name);
    Object.entries(attributes || {}).forEach(([key, value]) => node.setAttribute(key, String(value)));
    return node;
  }

  function byteStringToText(encoded) {
    const bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }

  function showMessage(text) {
    viewer.replaceChildren(Object.assign(document.createElement("p"), { className: "message", textContent: text }));
  }

  function bounds(elements) {
    const active = elements.filter((element) => element && element.isDeleted !== true && Number.isFinite(element.x) && Number.isFinite(element.y));
    if (active.length === 0) return { x: 0, y: 0, width: 1, height: 1 };
    const left = Math.min(...active.map((element) => element.x));
    const top = Math.min(...active.map((element) => element.y));
    const right = Math.max(...active.map((element) => element.x + (Number(element.width) || 0)));
    const bottom = Math.max(...active.map((element) => element.y + (Number(element.height) || 0)));
    return { x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) };
  }

  function renderElement(element) {
    const color = typeof element.strokeColor === "string" ? element.strokeColor : "currentColor";
    const common = { transform: `translate(${element.x || 0} ${element.y || 0})`, color };
    let node;
    switch (element.type) {
      case "rectangle":
        node = makeSVG("rect", { ...common, class: "shape", width: Math.max(0, element.width || 0), height: Math.max(0, element.height || 0), rx: element.roundness ? 8 : 0 });
        break;
      case "ellipse":
        node = makeSVG("ellipse", { ...common, class: "shape", cx: Math.max(0, element.width || 0) / 2, cy: Math.max(0, element.height || 0) / 2, rx: Math.max(0, element.width || 0) / 2, ry: Math.max(0, element.height || 0) / 2 });
        break;
      case "diamond":
        node = makeSVG("polygon", { ...common, class: "shape", points: `${(element.width || 0) / 2},0 ${(element.width || 0)},${(element.height || 0) / 2} ${(element.width || 0) / 2},${(element.height || 0)} 0,${(element.height || 0) / 2}` });
        break;
      case "text":
        node = makeSVG("text", common);
        node.textContent = typeof element.text === "string" ? element.text : "";
        break;
      case "line":
      case "arrow":
      case "freedraw": {
        const points = Array.isArray(element.points) ? element.points : [];
        node = makeSVG("polyline", { ...common, class: "line", points: points.map((point) => `${point[0]},${point[1]}`).join(" ") });
        break;
      }
      default:
        return null;
    }
    if (typeof element.link === "string" && /^https?:\/\//i.test(element.link)) {
      const anchor = makeSVG("a", { href: element.link });
      anchor.append(node);
      return anchor;
    }
    return node;
  }

  function render(documentValue) {
    if (documentValue.type !== "excalidraw" || documentValue.version !== 2 || Array.isArray(documentValue.elements) === false) {
      showMessage("This drawing is not a supported Excalidraw document.");
      return;
    }
    const svg = makeSVG("svg", { class: "scene", role: "img", "aria-label": "Read-only Excalidraw drawing" });
    const scene = makeSVG("g");
    documentValue.elements.map(renderElement).filter(Boolean).forEach((node) => scene.append(node));
    svg.append(scene);
    viewer.replaceChildren(svg);

    const drawingBounds = bounds(documentValue.elements);
    const view = { scale: 1, x: -drawingBounds.x + 24, y: -drawingBounds.y + 24 };
    function applyView() { scene.setAttribute("transform", `translate(${view.x} ${view.y}) scale(${view.scale})`); }
    function setScale(next) { view.scale = Math.min(maximumScale, Math.max(minimumScale, next)); }
    applyView();

    let drag = null;
    svg.addEventListener("pointerdown", (event) => {
      if (event.target.closest("a")) return;
      viewer.focus({ preventScroll: true });
      drag = { x: event.clientX, y: event.clientY, viewX: view.x, viewY: view.y };
      svg.setPointerCapture(event.pointerId);
    });
    svg.addEventListener("pointermove", (event) => {
      if (!drag) return;
      view.x = drag.viewX + event.clientX - drag.x;
      view.y = drag.viewY + event.clientY - drag.y;
      applyView();
    });
    svg.addEventListener("pointerup", () => { drag = null; });
    svg.addEventListener("pointercancel", () => { drag = null; });
    svg.addEventListener("wheel", (event) => {
      event.preventDefault();
      const next = event.deltaY < 0 ? view.scale * zoomFactor : view.scale / zoomFactor;
      setScale(next);
      applyView();
    }, { passive: false });
    viewer.addEventListener("keydown", (event) => {
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

  function readAuthorizedInput() {
    const rawInput = document.documentElement.dataset.rendererInput;
    if (!rawInput) {
      showMessage("The authorized drawing input is unavailable.");
      return;
    }
    let input;
    try { input = JSON.parse(rawInput); }
    catch (_) { showMessage("The authorized drawing input is unavailable."); return; }
    window.addEventListener("message", function receiveInput(event) {
      const response = event.data && event.data.rendererBridgeResponse;
      if (typeof response !== "string") return;
      try {
        const decoded = JSON.parse(response);
        if (decoded.id !== requestID || !decoded.payload || typeof decoded.payload.bytes !== "string") return;
        window.removeEventListener("message", receiveInput);
        render(JSON.parse(byteStringToText(decoded.payload.bytes)));
      } catch (_) {
        showMessage("The drawing could not be read.");
      }
    });
    window.postMessage({ rendererBridge: JSON.stringify({ id: requestID, method: "input.read", input }) }, "*");
  }

  readAuthorizedInput();
}());
