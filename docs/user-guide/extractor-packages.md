# Extractor packages

An extractor package converts one source format to Markdown. The app uses extractor packages when it ingests a PDF or HTML source and produces a Markdown page. A package is one folder that contains `manifest.json` and the files the manifest declares.

This Mac ships with two reviewed packages:

| Package | Format | What it does | Runtime it needs |
| --- | --- | --- | --- |
| Defuddle | HTML | Extracts the article body and article metadata | [Bun](https://bun.sh) |
| pdf2md | PDF | Converts a PDF to Markdown. It can download its model. | [uv](https://docs.astral.sh/uv/) |

The app installs both packages into a machine catalog the first time it runs. You do not enable a package for each wiki. Every compatible installed package is available to every wiki on this Mac.

## Trust

An extractor package contains executable code. Installing one authorizes that code to run on this Mac with your user account.

Two facts bound the risk, and neither is a sandbox:

- A package runs in a separate one-shot process with a fixed environment. It does not receive your credentials, API tokens, or wiki database paths.
- Each package is one exact reviewed revision. The app stores the SHA-256 digest of every declared file and refuses to run bytes that do not match.

The capability list in a manifest (network, shared caches, model download) is a reviewed declaration about behavior. It is not an operating-system restriction.

## Selection and fallback

Open **Settings** → **Extraction** and use the **Default Extractors** section. The PDF and HTML pickers list all compatible choices in one place:

- **Reviewed package** identifies bundled, validated packages such as pdf2md and Defuddle.
- **Installed package** identifies a package imported on this Mac.
- **Connected service** identifies a host-managed adapter such as ACP Provider or Docling Serve. Select Claude, Gemini, or another configured agent inside ACP Provider.
- **Built in** identifies code that runs in the host, such as tag-based HTML extraction.

A package selection does not pin a version. The app uses the highest compatible active revision of that package lineage. If the selected package is missing, failed, or incompatible, the picker keeps the unavailable selection visible and the app uses the fixed fallback: reviewed pdf2md for PDF or built-in tag-based extraction for HTML. The app never selects another third-party package silently.

Older package versions stay available while a newer version is installed, so a failed upgrade does not remove a working version.

## Installed packages in Settings

Use **Installed Extractor Packages** to manage exact revisions. This section does not contain another default picker. Expand a row to see its version, digest prefix, and registration name.

Use **Refresh** after you install, update, or remove a runtime such as Bun or uv. The list reads the live process state, so a row appears only when its package has activated in this process.

Lifecycle states use plain terms: a package is **Active** when you can select it. A package can also wait for a host service, fail to activate, or be in the process of stopping or removal. Raw identifiers and detailed history stay behind the disclosure rows.

## Runtime setup

Defuddle needs Bun. pdf2md needs uv. Both are optional: without them, package extraction fails with a clear cause and the built-in fallback runs instead. The app looks for runtime commands in the standard search paths, including the mise shim directory (`~/.local/share/mise/shims`), `~/.local/bin`, Homebrew, and system paths.

pdf2md can download a model on first use because its manifest declares the model-download capability. The app does not download a model on its own.

## Import and removal

Import accepts one local folder. It does not accept ZIP files, other archives, remote catalogs, or network installation. The app validates the folder, copies it to a private machine store, and verifies every file digest before it runs anything. The source folder is not used after import. A package cannot replace a different package under the same name and version.

Removing a package deletes its copied payload from this Mac and falls back to the built-in backends. Your sources and your selections are preserved.

Package data is machine-scoped. It does not appear in any wiki, in the File Provider, or in another Mac's store.

## Diagnostics

Extractor diagnostics are redacted. They identify the package lineage, version, digest prefix, registration, and failure phase. They do not contain source content, full paths, environment values, credentials, or unbounded process output.

## Relation to renderer packages

[Renderer packages](renderer-packages.md) add read-only views for page content. Extractor packages produce Markdown at ingestion. The two systems do not share an execution or security model. Each has its own manifest format and validation rules. A package cannot act as both.

Package authors and maintainers use the [extractor package maintainer](../skills/extractor-package-maintainer/SKILL.md) workflow. The normative references live under [docs/architecture](../architecture/extractor-script-protocol.md).
