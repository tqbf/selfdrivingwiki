# SVG renderer package provenance

The SVG renderer package contains no third-party engine bytes. Its viewer is
original to this repository and renders the authorized source through
WebKit's native SVG image mode; there is nothing vendored to attribute.

- `index.html` — original package shell, authored for this package.
- `viewer.js` — original driver, modeled on the repository's Mermaid package
  driver (input.read bridge relay, bounded load budget, error-region only
  failure reporting) and the retired built-in `SVGRendererView` display
  contract (exact bytes as a base64 `data:` image in WebKit image mode).

No build step, no network fetch, no external assets.
