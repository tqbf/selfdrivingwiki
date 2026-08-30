# Extractor packages

An extractor package converts one source format to Markdown. The app uses extractor packages when it converts a PDF, HTML, or Word source and produces a Markdown page. A package is one folder that contains `manifest.json` and the files the manifest declares.

This Mac ships with four reviewed packages:

| Package | Format | What it does | Runtime it needs |
| --- | --- | --- | --- |
| Defuddle | HTML | Extracts the article body and article metadata | [Bun](https://bun.sh) |
| pdf2md | PDF | Converts a PDF to Markdown. It can download its model. | [uv](https://docs.astral.sh/uv/) |
| Docling Serve | PDF | Sends the PDF to your self-hosted [Docling Serve](https://github.com/DS4SD/docling-serve) and stores the Markdown it returns. Optional API token; endpoint and timeout are set in Settings. | [`python3`](https://www.python.org) |
| docx2md | Word (.docx) | Converts a Word document to Markdown offline at import. **Extract** retries a failed conversion. | [Bun](https://bun.sh) |

### Word documents (.docx)

Drop a `.docx` into a wiki and it converts automatically: the reviewed
docx2md registration declares the Word MIME type and the `.docx` extension,
and those declared inputs are what recognize the file (a `.docx` is a zip
container the byte sniffer alone cannot tell apart from any archive). With
the registration active, extraction runs at import and the Markdown appears
as a derived version. The source keeps its original bytes, as with HTML
sources.

- Scope is `.docx` only. Legacy `.doc` and macro `.docm` files have no
  extraction path.
- Embedded images are not extracted. Each image becomes a
  `![Figure N](figure-N.png)` placeholder, and the result carries a warning
  that says how many images were skipped.
- docx2md needs [Bun](https://bun.sh). If Bun is missing, extraction fails
  with a clear cause. The import stores the file, and the **Extract** button
  remains the manual retry.
- A `.docx` source is not staged to agents until it has a Markdown version.
  The raw bytes are a binary zip with no value as agent context.

The app installs the packages into a machine catalog the first time it runs. You do not enable a package for each wiki. Every compatible installed package is available to every wiki on this Mac.

## Trust

An extractor package contains executable code. Installing one authorizes that code to run on this Mac with your user account.

Two facts bound the risk, and neither is a sandbox:

- A package runs in a separate one-shot process with a fixed environment. It does not receive your credentials, API tokens, or wiki database paths.
- Each package is one exact reviewed revision. The app stores the SHA-256 digest of every declared file and refuses to run bytes that do not match.

The capability list in a manifest (network, shared caches, model download) is a reviewed declaration about behavior. It is not an operating-system restriction.

## Selection and route status

Open **Settings** → **Extraction** and use the **Default Extractors** section. The table has one row for each extraction route. The current routes are PDF, HTML, and Word (.docx). A registration can add a row for a new format without an app update. Formats without a route do not have an extraction adapter yet.

Each row has four columns:

- **Format** shows the route name, such as PDF or HTML. Help text shows the MIME type.
- **Default extractor** lists reviewed packages, installed packages, connected services, and built-in extractors. HTML also has a no-default prompt choice.
- **Status** shows **Ready**, **Needs setup**, **Not installed**, **Starting**, or **Failed**.
- **Configuration** shows **Configure…** when the selected extractor has host settings.

A package selection does not pin a version. The app uses the highest compatible active revision from the selected package lineage.

An explicit unavailable selection stays selected and blocks that route. The app does not run another extractor automatically. Select a different extractor if you want to change the route.

Activate a non-ready status to open **Extractor Status**. The sheet explains the cause and confirms that the route is blocked. It shows only actions that can help the current state. These actions can include **Configure…**, **Authorize Credential…**, **Test Connection**, **Retry Activation**, **Refresh Status**, **Choose Another Extractor…**, and **Copy Diagnostics**.

Older package versions stay available while a newer version is installed. A failed new version does not remove a working older version.

## Installed packages in Settings

Use **Installed Extractor Packages** to manage exact revisions. This section does not contain another default picker or the local import workflow. Expand a row to see its version, digest prefix, and registration name.

Click the **Advanced Local Package Import** row to expand or contract it. Use the row's **Import Extractor Package…** button to add a local package folder. The app validates and copies the folder into the extractor store on this Mac.

Click an installed package row to expand or contract its details. Use **Refresh** after you install, update, or remove a runtime such as Bun or uv. The list reads the live process state, so a row appears only when its package has activated in this process.

Lifecycle states use plain terms: a package is **Active** when you can select it. A package can also wait for a host service, fail to activate, or be in the process of stopping or removal. Raw identifiers and detailed history stay behind the disclosure rows.

## Package credentials

Some packages declare that they need a credential. A package never receives
one until you authorize it. It receives only the credential that you authorize
for it.

Open the package configuration dialog to see each requirement. The dialog
shows its label, purpose, optionality, stored-value state, and authorization
state. For Docling Serve, use **Configure…** in the Default Extractors table.
For other packages, expand the row under **Installed Extractor Packages** and
select **Configure…**.

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
   default extractor.
3. Select **Configure…**, then set the **Endpoint** and optional **Timeout**.
   The default timeout is 600 seconds.
4. If your server uses `DOCLING_SERVE_API_KEY`, paste the token and select
   **Save Token**. The app stores the token in your Keychain and never shows it
   again.
5. In the same dialog, select **Authorize…** for the **Docling Serve API
   token** requirement. The token is optional. The package sends no
   authentication header when you do not authorize it.
6. Use **Test Connection** to verify the endpoint. The settings window never
   receives the stored token.

## Runtime setup

Defuddle and docx2md need Bun. pdf2md needs uv. All runtimes are optional. If a selected package cannot find its runtime, that route fails with a clear cause. The app does not run another extractor automatically. The app looks for runtime commands in the standard search paths, including the mise shim directory (`~/.local/share/mise/shims`), `~/.local/bin`, Homebrew, and system paths.

pdf2md can download a model on first use because its manifest declares the model-download capability. The app does not download a model on its own.

## Import and removal

Import accepts one local folder. It does not accept ZIP files, other archives, remote catalogs, or network installation. The app validates the folder, copies it to a private machine store, and verifies every file digest before it runs anything. The source folder is not used after import. A package cannot replace a different package under the same name and version.

Removing a package deletes its copied payload from this Mac. Your sources and selections remain. If the package is selected, that route stays blocked until you select another extractor.

Package data is machine-scoped. It does not appear in any wiki, in the File Provider, or in another Mac's store.

## Diagnostics

Open **Technical Details** in the **Extractor Status** sheet to preview a deterministic redacted report. **Copy Diagnostics** copies the same text that the sheet shows.

The report can identify the extractor, package, registration, version, digest prefix, route, health category, and bounded host failure message. It can also include safe setup facts, such as an ACP provider ID or a Docling endpoint origin.

The Docling endpoint contains only its scheme, host, and optional port. The report does not include URL user information, paths, queries, fragments, credential values, headers, source content, private paths, environment values, Keychain locations, or raw package output.

Settings reports route health for configuration, authorization, connection checks, package presence, host activation, and selection availability. A document extraction failure remains in **Activity**. It does not change the Settings route status.

## Relation to renderer packages

[Renderer packages](renderer-packages.md) add read-only views for page content. Extractor packages produce Markdown at ingestion. The two systems do not share an execution or security model. Each has its own manifest format and validation rules. A package cannot act as both.

Package authors and maintainers use the [extractor package maintainer](../skills/extractor-package-maintainer/SKILL.md) workflow. The normative references live under [docs/architecture](../architecture/extractor-script-protocol.md).
