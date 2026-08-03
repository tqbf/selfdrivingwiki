# Vendored: apple-podcast-transcript-downloader

- **Upstream:** https://github.com/dado3212/apple-podcast-transcript-downloader
- **Author:** Alex Beals (@dado3212)
- **Commit:** `535e0ce8ddb609f27ee5b169d910b3517944e9f6` (HEAD as of 2026-07-03)
- **License:** upstream publishes no license file. Vendored for personal,
  non-distributed use only (see `plans/podcast-transcripts.md` — this whole
  feature uses private API and is not distributable anyway).
- **Files:** `FetchTranscript.m` and `README.md`, verbatim.

`FetchTranscript.m` is the reference for the FairPlay/Mescal
`X-Apple-ActionSignature` bearer-token flow (dlopen `PodcastsFoundation`,
`AMSMescal _signedActionDataFromRequest:policy:`,
`AMSMescalSession signData:bag:`). The adapted, in-tree version is the
`podcast-token-helper` target (`Sources/PodcastTokenHelper/`) — trimmed to
token-fetch only (the AMP/TTML legs are Swift in `WikiFSCore`). Keep this
verbatim copy pinned so the signing logic can be re-derived if the private
selectors change in a macOS update.

Upstream build (for re-verification):

```
clang -Wno-objc-method-access -framework Foundation \
  -F/System/Library/PrivateFrameworks -framework AppleMediaServices \
  FetchTranscript.m -o FetchTranscript
./FetchTranscript 1000774368453
```

Verified working on this machine (Darwin 25.5) on 2026-07-03: produced a valid
`ey…` JWT and downloaded `transcript_1000774368453.ttml` (927 KB).
