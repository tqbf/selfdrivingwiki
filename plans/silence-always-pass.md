# Silence "will always pass" warnings

Swift Testing warns on `#expect(true)` (literal `true` — always passes). The
warning message itself says: "use `Bool(true)` to silence this warning". The
codebase already uses this silencer at
`Tests/WikiFSTests/NotificationFanoutTests.swift:76` (`#expect(Bool(true))`).

## Fix (test-file only — no non-test source touched)

1. `Tests/WikiFSTests/WikiChangeBridgeTests.swift:176` — `#expect(true)` →
   `#expect(Bool(true))` (no-crash test for non-matching wikiID flush; comment
   preserved).
2. `Tests/WikiFSTests/QuoteHighlightWebViewTests.swift:112` — `#expect(true)` →
   `#expect(Bool(true))` (diagnostic/probe test; surrounding probe code
   preserved).

Do NOT alter any `#expect(... == true)` expressions — those are real Bool
comparisons, not tautological literals, and do not fire the warning.

## Verify

`make build && make test` — confirm the two warnings are gone.

## Ship

Push branch, open PR (no `Closes` issue — standalone warning cleanup). Do NOT
merge to main.
