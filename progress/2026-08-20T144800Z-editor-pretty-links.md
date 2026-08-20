# Editor pretty links

Date: 2026-08-20
Issue: #255

## Result

The page editor now hides canonical page ULIDs when a link has a safe alias.
For example, it shows `[[page:01H...|Home]]` as `[[Home]]`.

The editor keeps source and chat namespaces when it presents a link. It also
preserves embed markers, fragments, and version pins.

The projection runs only in the editor. Stored Markdown remains canonical, and
the existing page save path still owns canonicalization.

Links in code, unresolved links, links without aliases, and ambiguous aliases
remain unchanged. This prevents the editor view from changing link meaning.

## Implementation

- `WikiLinkEditorProjection` provides a pure, code-span-safe display transform.
- `ScrollableTextEditor` accepts an optional display transform.
- `PageDetailView` supplies the ULID-hiding transform.
- Autocomplete and sidebar drops keep canonical binding values and re-present
  inserted links without showing the ULID.

## Verification

- `swift test --filter WikiLinkEditorProjectionTests` passed: 5 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter EditorAutocompleteHostedTests` passed:
  13 tests.
- `make build` passed, including app assembly, signing, and resource bundling.
- `make test` passed: 3,483 tests in 336 suites.
