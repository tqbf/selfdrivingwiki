## Renderer package chat reference

Self Driving Wiki manages the reviewed read-only Excalidraw renderer and makes every compatible validated installed renderer available to every wiki. Renderer packages are machine-scoped; persisted wiki enablement rows remain compatibility data and do not control availability.

Advanced renderer import accepts one local directory only. The app validates and copies it into machine-local storage. Source fallback and native renderers remain available when a package is absent, incompatible, suppressed, or unavailable.

Installed web packages are served only through the validated `renderer-package` resource boundary. They have no direct file or network URL access. The host exposes only the authorized read-only input for the active source.

This short reference is context for wiki operations. It is not a system prompt and does not execute the `renderer-package-maintainer` skill.
