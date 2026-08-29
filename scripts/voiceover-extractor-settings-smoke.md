# Extractor settings VoiceOver smoke test

Run this test on macOS with VoiceOver enabled. Use a test App Group and a disposable extractor package.

1. Open Self Driving Wiki Settings.
2. Select the Extraction tab.
3. Move focus to the `Default extractor routes` table.
4. Confirm that VoiceOver announces PDF before HTML.
5. Move to each default-extractor pop-up.
6. Confirm that VoiceOver reads the format and selected extractor.
7. Open the PDF pop-up.
8. Confirm that each option reads its name and source.
9. Select ACP Provider.
10. Confirm that **Configure…** appears in the Configuration column.
11. Select Docling Serve.
12. Confirm that **Configure…** remains in the Configuration column.
13. Activate **Configure…**.
14. Confirm that the dialog contains Endpoint, Timeout, and API Token fields.
15. Confirm that VoiceOver never reads the stored token.
16. Close the configuration dialog.
17. Create one **Needs setup** state, such as an invalid Docling endpoint.
18. Move focus to the route status.
19. Confirm that VoiceOver reads the format, selected extractor, complete cause, and `Show status details`.
20. Activate the status.
21. Confirm that the **Extractor Status** sheet opens.
22. Confirm that VoiceOver reads the title and specific cause.
23. Confirm that VoiceOver reads that the route is blocked.
24. Confirm that VoiceOver reads that no other extractor will run automatically.
25. Confirm that the sheet offers only useful actions for this state.
26. Activate **Configure…** from the sheet.
27. Confirm that the status sheet closes before the configuration dialog opens.
28. Create a missing-authorization state for Docling Serve.
29. Open **Extractor Status** again.
30. Confirm that **Authorize Credential…** is available.
31. Confirm that the authorization dialog opens after the status sheet closes.
32. Create a failed Docling connection-test state.
33. Confirm that the route reads **Needs setup**.
34. Open **Extractor Status** and activate **Test Connection**.
35. Confirm that VoiceOver announces progress and completion.
36. Create a **Starting** package state.
37. Open **Extractor Status** and activate **Retry Activation**.
38. Confirm that duplicate actions stay disabled during progress.
39. Confirm that VoiceOver announces completion and the route status refreshes.
40. Open a non-ready status and activate **Choose Another Extractor…**.
41. Confirm that the sheet closes and focus moves to that route's picker.
42. Open **Technical Details**.
43. Confirm that VoiceOver reads the redacted diagnostic report.
44. Activate **Copy Diagnostics**.
45. Confirm that the copied text equals the report in the sheet.
46. Confirm that the report contains no token, header, URL path, URL query, source content, or private path.
47. Activate **Done** and confirm that the sheet closes.
48. Open **Advanced Local Package Import**.
49. Confirm that VoiceOver reads the executable-code warning.
50. Import the disposable package and select it for its route.
51. Confirm that the selected route reads **Ready**.
52. Activate **Remove Package…**.
53. Confirm that the dialog says removal blocks a selected route.
54. Remove the package.
55. Confirm that VoiceOver announces removal progress and completion.
56. Confirm that the unavailable selection remains selected.
57. Confirm that the route reads **Not installed**.
58. Open **Extractor Status**.
59. Confirm that the sheet offers refresh, another selection, and diagnostic copy actions.
60. Confirm that the app does not select or run another extractor automatically.
61. Tab through the section and confirm a logical focus order.

Record the macOS version, app build, package digest prefix, and each incorrect announcement. Do not record source content or credentials.
