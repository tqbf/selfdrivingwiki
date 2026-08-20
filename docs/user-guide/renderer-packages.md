# Renderer packages

A renderer package adds a local read-only view for a supported source format. A package is one folder on your Mac.

The folder contains `manifest.json` and the static files that the manifest declares. Static files can include HTML, JavaScript, CSS, images, and fonts.

```text
ExampleRenderer/
├── manifest.json
└── index.html
```

`manifest.json` identifies the package. It also declares matching rules, capabilities, limits, assets, and SHA-256 digests.

## Import a package

1. Open **Settings**.
2. Select **Renderers**.
3. Open **Advanced Local Renderer Package Import**.
4. Select **Import Local Renderer Package**.
5. Select the package folder.

The app validates the folder before installation. It rejects missing files, undeclared files, invalid paths, unsupported files, and incorrect digests.

The app copies a valid package for use on this Mac. The app does not use the selected source folder after import.

Every compatible installed renderer is available to every wiki on this Mac. You do not enable a package for each wiki.

Import accepts one local folder. It does not accept ZIP files, other archives, remote catalogs, signing services, or network installation.

## Preferences and fallback

A source can use a logical renderer preference or an exact package version. A preference does not install a package or change another source.

If a package is absent or incompatible, the app keeps Source and native renderer fallback available. The same fallback applies after a renderer failure.

Safe mode can suppress one package version after repeated failures. Resetting safe mode restores that version. It does not change source preferences.

Removing a package deletes its copied payload from this Mac. It does not delete source data or source preferences.

## Author a package

Most users only import packages. Package authors must define the full manifest, asset digests, security limits, and accessibility values.

Repository agents and developers must use the [`renderer-package-maintainer`](../skills/renderer-package-maintainer/SKILL.md) workflow. They must validate a package before a user imports it.
