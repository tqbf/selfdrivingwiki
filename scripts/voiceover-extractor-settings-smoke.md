# Extractor settings VoiceOver smoke test

Run this test on macOS with VoiceOver enabled. Use a test App Group and a disposable extractor package.

1. Open Self Driving Wiki Settings.
2. Select the Extraction tab.
3. Move focus to the `Default extractor routes` table in the Default Extractors section.
4. Confirm that VoiceOver announces the two canonical rows, PDF first and HTML second.
5. In each row, move to the `Default extractor for PDF` / `Default extractor for HTML` pop-up.
6. Confirm that VoiceOver reads the selected extractor and the status (for example `pdf2md, Available`).
7. Open the PDF pop-up. Confirm the option captions read `name — source` (Reviewed package, Installed package, Connected service, Built in).
8. Choose the ACP Provider option. Confirm a `Configure…` button appears in that row's Configuration column, and VoiceOver announces focus movement to the next control after the table.
9. Choose the Docling Serve option. Confirm a `Configure…` button appears in that row's Configuration column instead of inline fields.
10. Activate `Configure…`. Confirm the configuration dialog opens with the Endpoint, Timeout, and write-only API Token fields, and that the stored token itself is never spoken.
11. Focus the `API Token` field. Confirm VoiceOver announces the placeholder (`Configured — enter a new token to replace` when a token is stored, `Enter token` otherwise).
12. Activate `Save Token`. Confirm VoiceOver announces the `Token configured` status and the field clears.
13. Activate `Remove Token`. Confirm the status announces `No token stored`.
14. Activate `Done` to close the dialog.
15. Move focus to the `Package Credentials` section. Confirm VoiceOver reads one row per declared requirement with the label, purpose, package name, optionality (optional or required), and authorization state (`Authorized`, `Needs authorization`, or `Changed — re-authorization needed`).
16. Activate `Authorize…` on a requirement. Confirm the dialog states the inheritance rule (future revisions keep the grant only while the requirement stays unchanged) before `Authorize` and `Cancel`.
17. Activate `Authorize`. Confirm the row announces `Authorized`.
18. Activate `Revoke…`. Confirm the dialog states that revoking the grant does not delete the stored credential, then activate `Revoke`. Confirm the row announces `Needs authorization` again.
19. Choose the reviewed pdf2md option. Confirm no service section remains.
18. Move focus to a Status cell that reads `Using fallback`. Activate the help text. Confirm VoiceOver reads the fallback that actually runs (Bundled pdf2md extraction or Tag-based text extraction).
19. Move focus to `Advanced Local Package Import`.
20. Confirm that VoiceOver reads the executable-code warning.
21. Confirm that VoiceOver reads that the app's lifecycle and capability controls do not create a security sandbox.
22. Open the import disclosure.
23. Activate `Import Extractor Package`.
24. Choose one local package directory.
25. Confirm that VoiceOver reads `Validating and installing package`.
26. Confirm that VoiceOver reads the successful installation announcement.
27. Move focus to an installed package row in Installed Extractor Packages.
28. Confirm that VoiceOver reads the package name, version, kind, and `Active` state.
29. Open the row disclosure.
30. Confirm that VoiceOver reads the digest prefix, registration, and readiness state.
31. Select the package in the PDF route pop-up. Confirm the status column reads `Available` and the picker's accessibility value contains the package name.
32. Activate `Remove Package`.
33. Confirm the destructive dialog text and `Cancel` action.
34. Activate `Remove Package` in the dialog.
35. Confirm that VoiceOver reads `Removing package` and the successful removal announcement.
36. Confirm that the logical selection remains selected in the route pop-up as `Not installed` and the status column reads `Using fallback`.
37. Confirm the row is removed and the documented built-in fallback remains active.
38. Tab through the section: confirm focus moves row by row between the route pop-ups, then reaches the package controls after the table.

Record the macOS version, app build, package digest prefix, and any missing or incorrect announcement. Do not record package source content or credentials.
