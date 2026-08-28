---
timestamp: 2026-08-28T050000Z
title: Package-first extractor settings
branch: feature/dynamic-extractor-packages
status: complete
---

# Package-first extractor settings

## Progress

Settings → Extraction now presents one default extractor picker per content type.

- The PDF picker lists reviewed pdf2md, imported PDF packages, ACP, Claude, Gemini, and Docling Serve.
- The HTML picker lists reviewed Defuddle, imported HTML packages, and built-in tag-based extraction.
- Each choice identifies its source as Reviewed package, Installed package, Connected service, or Built in.
- The package management section no longer contains a second default-selection picker.
- Selecting a connected PDF service shows its configuration section below the default pickers.
- Podcast transcript selection remains separate because extractor protocol revision 1 does not support transcripts.
- Missing imported packages remain visible as unavailable selections with their fixed fallback state.

The UI uses kind-specific selection enums. It cannot put an HTML adapter in the PDF picker or a PDF adapter in the HTML picker.

Compatibility mapping preserves existing configuration files:

- reviewed pdf2md writes the reviewed logical package reference and keeps `backend = localPdf2md`;
- reviewed Defuddle writes the reviewed logical package reference and keeps `htmlBackend = defuddle`;
- connected and built-in choices update both the legacy field and the tagged built-in reference;
- imported package choices update the logical package reference and preserve the legacy field;
- the HTML prompt choice clears both HTML selection fields.

## Verification

The following gates passed on 2026-08-28:

```text
make build

WIKIFS_APP_TESTS=1 swift test --filter ExtractorPackageSettingsTests
19 tests passed

swift test --filter 'ExtractionConfigTests|ReviewedLegacySelectionMappingTests|ExtractionRuntimeFactoryTests|InstalledExtractorFallbackTests'

swift test --filter DocumentationContractTests

make lint

make test
3,851 tests passed in 403 suites
```

The tests cover legacy selection loading, reviewed package mapping, host-service compatibility fields, imported-package fallback preservation, HTML prompt behavior, wrong-kind persisted references, picker validation, accessibility identifiers, and package lifecycle behavior.
