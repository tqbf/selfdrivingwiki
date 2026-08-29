# Extractor packages

An extractor package converts one source format to Markdown. The app uses extractor packages when it ingests a PDF or HTML source and produces a Markdown page. A package is one folder that contains `manifest.json` and the files the manifest declares.

This Mac ships with three reviewed packages:

| Package | Format | What it does | Runtime it needs |
| --- | --- | --- | --- |
| Defuddle | HTML | Extracts the article body and article metadata | [Bun](https://bun.sh) |
| pdf2md | PDF | Converts a PDF to Markdown. It can download its model. | [uv](https://docs.astral.sh/uv/) |
| Docling Serve | PDF | Sends the PDF to your self-hosted [Docling Serve](https://github.com/DS4SD/docling-serve) and stores the Markdown it returns. Optional API token; endpoint and timeout are set in Settings. | [`python3`](https://www.python.org) |

The app installs the packages into a machine catalog the first time it runs. You do not enable a package for each wiki. Every compatible installed package is available to every wiki on this Mac.

## Trust

An extractor package contains executable code. Installing one authorizes that code to run on this Mac with your user account.

Two facts bound the risk, and neither is a sandbox:

- A package runs in a separate one-shot process with a fixed environment. It does not receive your credentials, API tokens, or wiki database paths.
- Each package is one exact reviewed revision. The app stores the SHA-256 digest of every declared file and refuses to run bytes that do not match.

The capability list in a manifest (network, shared caches, model download) is a reviewed declaration about behavior. It is not an operating-system restriction.

## Selection and fallback

Open **Settings** → **Extraction** and use the **Default Extractors** section. The section shows a table with one row per extraction route. The current routes are PDF and HTML. A registration can add a row for a new format without another app update, although formats outside PDF and HTML have no extraction adapter yet.

Each row has three columns:

- **Format** shows the route name, such as PDF or HTML. The technical MIME type is in the help text.
- **Default extractor** is a pop-up that lists the compatible choices for that row: reviewed packages, installed packages, connected services, and built-in extractors. HTML also offers a no-default prompt choice. The labels match the older pickers: **Reviewed package**, **Installed package**, **Connected service**, and **Built in**.
- **Status** shows **Available**, **Using fallback**, **Not installed**, **Waiting for host service**, or **Failed to activate**. When the status is **Using fallback**, the help text names the fallback that actually runs.

A package selection does not pin a version. The app uses the highest compatible active revision of that package lineage. If the selected package is missing, failed, or incompatible, the pop-up keeps the unavailable selection selected and the app uses the fixed fallback: reviewed pdf2md for PDF or built-in tag-based extraction for HTML. The app never selects another third-party package silently.

Older package versions stay available while a newer version is installed, so a failed upgrade does not remove a working version.

## Installed packages in Settings

Use **Installed Extractor Packages** to manage exact revisions. This section does not contain another default picker. Expand a row to see its version, digest prefix, and registration name.

Use **Refresh** after you install, update, or remove a runtime such as Bun or uv. The list reads the live process state, so a row appears only when its package has activated in this process.

Lifecycle states use plain terms: a package is **Active** when you can select it. A package can also wait for a host service, fail to activate, or be in the process of stopping or removal. Raw identifiers and detailed history stay behind the disclosure rows.

## Package credentials

Some packages declare that they need a credential. A package never receives
one until you authorize it, and it receives only the credential you
authorized for it.

Use the **Package Credentials** section (below **Installed Extractor
Packages**) to see each requirement's label, purpose, whether it is optional
or required, whether a value is stored, and its authorization state:

- **Needs authorization** — the package declared a credential but you have
  not granted it. Enter the value in **Settings** (provider credentials live
  under **Settings** → the relevant provider; the Docling token under
  **Settings** → **Extraction** → Docling Serve), then press **Authorize…**.
- **Authorized** — the package receives the credential the next time it
  runs. Rotating the value in Settings takes effect on the next run; you do
  not re-authorize.
- **Changed — re-authorization needed** — the package update changed the
  requirement (its label, purpose, optionality, or registration), so the old
  grant no longer applies. Review and authorize again.

Press **Revoke…** to withdraw a grant. Revoking removes the authorization,
not the stored value; the package stops receiving the credential on its next
run. If you remove an authorized package, its grant is kept attached to that
package's identity so a reinstall shows (and can revoke) the stale grant —
it never transfers to a different package.

Authorization follows future updates of the same package only while the
requirement stays exactly as you approved it. The confirmation dialog states
this before you approve.

Credential values are stored in your Keychain. They are never shown in
Settings after you save them, never written into any config file, catalog,
or log, and never placed in a package's environment variables: the app hands
the authorized values to the package process through a private,
owner-read-only file that is deleted as soon as the request ends.

## Docling Serve setup

1. Run your Docling Serve instance (for example `docling-serve run`) and note
   its base URL.
2. In **Settings** → **Extraction**, select **Docling Serve** as the PDF
   default extractor and set the **Endpoint** (and optionally a
   **Timeout**; the default is 600 seconds).
3. If your server was started with `DOCLING_SERVE_API_KEY`, paste the token
   once and press **Save Token**. It is stored in your Keychain and is never
   displayed again.
4. Press **Authorize…** on the **Docling Serve API token** requirement in
   **Package Credentials**. Until you authorize, a Docling selection shows
   its needs-authorization state and the extraction does not run.
5. Use **Test Connection** to verify the endpoint. The stored token is never
   returned to the settings window.

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
