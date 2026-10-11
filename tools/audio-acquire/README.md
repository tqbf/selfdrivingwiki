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
2. Runs ONE metadata-only yt-dlp call (`extract_info(download=False)`,
   `skip_download=True`) against the application-built watch URL, under a
   connection guard that permits `www.youtube.com:443` only and validates
   every DNS answer as globally routable.
3. Checks the metadata duration (present, at most 2 hours) and selects ONE
   audio-only M4A/AAC format (`ext=m4a`, `vcodec=none`, present `acodec`;
   best by audio bitrate, then format 140).
4. Fetches the signed media URL with the package's own streaming client:
   https on 443 only, host must be one-or-more labels plus the exact
   `.googlevideo.com` suffix, no redirects, no proxy inheritance, identity
   encoding, at most 120 MiB plus one byte, and the payload must begin
   with a nonempty M4A `ftyp` box.
5. Publishes the file atomically and emits one result frame with
   `resultType: "source-bytes"` and `resultMIMEType: "audio/mp4"`.

The package never converts formats, never runs speech-to-text, and never
touches yt-dlp's media downloader or ffmpeg. The HOST consumes the
acquired file transiently inside its own private analysis stage — audio is
never stored as a source blob.

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

- Metadata: `www.youtube.com` only. Media: one-or-more labels plus the
  exact `.googlevideo.com` suffix, on 443 only.
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
