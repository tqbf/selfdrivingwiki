# Extractor settings VoiceOver smoke test

Run this test on macOS with VoiceOver enabled. Use a test App Group and a disposable extractor package.

1. Open Self Driving Wiki Settings.
2. Select the Extraction tab.
3. Move focus to the `Default extractor routes` table in the Default Extractors section.
4. Confirm that VoiceOver announces the two canonical rows, PDF first and HTML second.
5. In each row, move to the `Default extractor for PDF` / `Default extractor for HTML` pop-up.
6. Confirm that VoiceOver reads the selected extractor and the status (for example `pdf2md, Available`).
7. Open the PDF pop-up. Confirm the option captions read `name — source` (Reviewed package, Installed package, Connected service, Built in).
8. Choose the ACP Provider option. Confirm the ACP Provider section appears below the table and VoiceOver announces focus movement to the next control after the table.
9. Choose the Docling Serve option. Confirm the Docling Serve section replaces it.
10. Choose the reviewed pdf2md option. Confirm no service section remains.
11. Move focus to a Status cell that reads `Using fallback`. Activate the help text. Confirm VoiceOver reads the fallback that actually runs (Bundled pdf2md extraction or Tag-based text extraction).
12. Move focus to `Advanced Local Package Import`.
13. Confirm that VoiceOver reads the executable-code warning.
14. Confirm that VoiceOver reads that the app's lifecycle and capability controls do not create a security sandbox.
15. Open the import disclosure.
16. Activate `Import Extractor Package`.
17. Choose one local package directory.
18. Confirm that VoiceOver reads `Validating and installing package`.
19. Confirm that VoiceOver reads the successful installation announcement.
20. Move focus to an installed package row in Installed Extractor Packages.
21. Confirm that VoiceOver reads the package name, version, kind, and `Active` state.
22. Open the row disclosure.
23. Confirm that VoiceOver reads the digest prefix, registration, and readiness state.
24. Select the package in the PDF route pop-up. Confirm the status column reads `Available` and the picker's accessibility value contains the package name.
25. Activate `Remove Package`.
26. Confirm the destructive dialog text and `Cancel` action.
27. Activate `Remove Package` in the dialog.
28. Confirm that VoiceOver reads `Removing package` and the successful removal announcement.
29. Confirm that the logical selection remains selected in the route pop-up as `Not installed` and the status column reads `Using fallback`.
30. Confirm the row is removed and the documented built-in fallback remains active.
31. Tab through the section: confirm focus moves row by row between the route pop-ups, then reaches the package controls after the table.

Record the macOS version, app build, package digest prefix, and any missing or incorrect announcement. Do not record package source content or credentials.
