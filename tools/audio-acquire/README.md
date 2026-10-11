# audio-acquire

The reviewed YouTube audio acquisition package source. `scripts/sync-extractor-packages.sh`
copies this script plus a generated entry point into
`ExtractorPackages/AudioAcquire` and pins the result with the reviewed
package digest.

## What it does

The package serves ONE extractor-protocol revision 5 `remote-url` FETCH
request (role `fetcher`, registration id `audio`, claimed source MIME
`audio/x-wiki-audio-acquire`):

1. Validates the request: revision, role, claimed MIME, no extractor kind
   or staged input, a YouTube video URL, a safe relative output path, and
   a valid deadline.
2. Runs ONE metadata-only yt-dlp call (`extract_info(download=False)`)
   against the application-built watch URL to validate the video (duration
   present, at most 2 hours) and confirm an audio-only M4A stream exists.
3. Downloads the selected audio-only M4A with the SAME pinned release's
   NATIVE downloader — the component that makes YouTube downloads fast and
   reliable — under the package's reduced posture: no plugins, no cookies,
   no netrc, no proxy inheritance, bounded retries, a 120 MiB
   `max_filesize` cap, and the package's connection guard wrapping every
   DNS answer and TCP connect (any hostname permitted; every resolved
   address must be globally routable; connections go to validated
   addresses with no second DNS lookup).
4. Validates the published file begins with a nonempty M4A `ftyp` box,
   then renames it atomically to the requested output path and emits one
   result frame with `resultType: "source-bytes"` and
   `resultMIMEType: "audio/mp4"`.

The package never post-processes (no ffmpeg), never selects a video
format, and never runs speech-to-text. The HOST consumes the acquired
file transiently inside its own private analysis stage — audio is never
stored as a source blob.

## Pinned dependencies

- `yt-dlp==2026.08.19` — the same pinned release the caption package
  reviews, imported with the `YTDLP_NO_PLUGINS` guard set, remote
  components refused, no cookies/netrc/proxies/retries.
- `yt-dlp-ejs==0.8.0` — the auxiliary challenge runtime resolver. The Bun
  executable path arrives through the host-owned operation configuration
  (`kind: "reviewed-audio-acquire-bun-runtime"`), granted only to this
  package's exact reviewed revision.

## Transport policy

Every DNS answer and every TCP connect passes through a connection guard
installed around the metadata and media phases:

- Metadata: `www.youtube.com` plus the `.googlevideo.com` family (the
  pinned release fetches HLS format manifests from it during format
  enumeration). Media: one-or-more labels plus the exact
  `.googlevideo.com` suffix, on 443 only.
- Every resolved IPv4/IPv6 answer must be globally routable; private,
  loopback, link-local, or mixed answers reject the whole lookup.
- Connections go to the validated addresses without a second DNS lookup
  while the URL hostname is retained for Host, TLS SNI, and certificate
  verification.
- Redirects are never followed; a changing answer cannot move a pinned
  connection.

Every failure message is a fixed string: the source URL, the signed media
URL, tokens, upstream error text, and media bytes never reach a frame or
stderr.

## Tests

```sh
# Dev suite (yt-dlp mocked; no network):
uv run --project . pytest tests/test_audio_acquire.py tests/test_network_policy.py -v

# Real pinned-library offline contract (runs inside the pinned PEP 723 env):
uv run --script tests/_ytdlp_offline_contract.py plugin-guard
uv run --script tests/_ytdlp_offline_contract.py contract
```

`test_network_policy.py` runs all three (the contract arms via
`uv run --script`); it is the AC.1 gate for the network rules.

## Redaction

The package reports fixed, bounded messages. It never logs the source URL,
the signed media URL, any token, media bytes, or upstream error text.
