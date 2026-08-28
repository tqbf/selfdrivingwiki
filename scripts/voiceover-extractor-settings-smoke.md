# Extractor settings VoiceOver smoke test

Run this test on macOS with VoiceOver enabled. Use a test App Group and a disposable extractor package.

1. Open Self Driving Wiki Settings.
2. Select the Extraction tab.
3. Move focus to `Advanced Local Package Import`.
4. Confirm that VoiceOver reads the executable-code warning.
5. Confirm that VoiceOver reads that Cordis lifecycle and capability controls do not create a security sandbox.
6. Open the import disclosure.
7. Activate `Import Extractor Package`.
8. Choose one local package directory.
9. Confirm that VoiceOver reads `Validating and installing package`.
10. Confirm that VoiceOver reads the successful installation announcement.
11. Move focus to an installed package row.
12. Confirm that VoiceOver reads the package name, version, kind, and `Active` state.
13. Open the row disclosure.
14. Confirm that VoiceOver reads the digest prefix, registration, and readiness state.
15. Select the package in the PDF or HTML extractor picker.
16. Confirm that VoiceOver reads the selected logical package reference.
17. Activate `Remove Package`.
18. Confirm the destructive dialog text and `Cancel` action.
19. Activate `Remove Package` in the dialog.
20. Confirm that VoiceOver reads `Removing package` and the successful removal announcement.
21. Confirm that the logical selection remains visible as `not installed`.
22. Confirm that the row is removed and the documented built-in fallback remains active.

Record the macOS version, app build, package digest prefix, and any missing or incorrect announcement. Do not record package source content or credentials.
