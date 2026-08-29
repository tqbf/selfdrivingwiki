"""Docling Serve extractor package source.

Reviewed source for the org.selfdrivingwiki.docling-serve package. Copied
into ExtractorPackages/DoclingServe/bin/ by scripts/sync-extractor-packages.sh;
the committed copy is digest-verified, so edit THIS file and regenerate.

Runs one protocol revision 2 request:

- reads the request JSON from stdin (paths are relative to the operation root);
- reads the non-secret public operation configuration (endpoint, timeout);
- reads ONLY the declared `api-token` credential from the private credential
  input file, when one was materialized;
- uploads the input PDF to `<endpoint>/v1/convert/file` as multipart form data
  with the token in the `X-Api-Key` header (and nowhere else);
- writes the returned Markdown to the requested output path;
- emits bounded protocol frames on stdout. Request headers, the credential
  input, and any token-bearing error detail are never printed.
"""

from __future__ import annotations

import json
import mimetypes
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlparse

_PROGRESS_LIMIT = 1024
_MAX_OUTPUT_BYTES = 128 * 1024 * 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Blocks redirect following for authenticated requests.

    urllib's default redirect handler re-sends headers — including
    X-Api-Key — to the redirect target, which may be a different origin or
    a plaintext downgrade. A 3xx is surfaced as an error instead.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _sanitize_filename(name: str) -> str:
    """Make `name` safe for a multipart Content-Disposition header.

    Strips CR/LF and other controls, backslash-escapes quotes and
    backslashes, so no part-header injection is possible (security review
    MEDIUM-6).
    """
    cleaned = "".join(
        character for character in name if ord(character) >= 32 and character != "\x7f"
    )
    return cleaned.replace("\\", "\\\\").replace('"', '\\"')


def _token_allowed_for(endpoint: str) -> bool:
    """The token is attached only for https endpoints or loopback http.

    Plaintext off-host transport would expose the token on the wire
    (security review HIGH-2a).
    """
    parsed = urlparse(endpoint)
    if parsed.scheme == "https":
        return True
    if parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "::1", "localhost"):
        return True
    return False


def _emit(frame: dict) -> None:
    sys.stdout.write(json.dumps(frame) + "\n")
    sys.stdout.flush()


def _fail(request_id: str, cause: str, message: str) -> None:
    _emit({
        "kind": "failure",
        "payload": {
            "requestID": request_id,
            "cause": cause,
            "message": message[:4096],
            "warnings": [],
        },
    })


def _read_optional_json(path: str | None) -> dict | None:
    if not path:
        return None
    candidate = Path(path)
    if not candidate.is_file():
        return None
    with candidate.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def run(request_text: str) -> int:
    try:
        return _run_guarded(request_text)
    except Exception:  # noqa: BLE001 — final boundary: a bounded frame, never a traceback
        # Any unexpected package-side failure must surface as a bounded
        # failure frame. A raw interpreter traceback could echo header values
        # (including the token) or operation paths to stderr (security
        # review MEDIUM-5).
        try:
            _fail("", "extraction-failure",
                  "The Docling Serve extractor failed unexpectedly.")
        except Exception:  # noqa: BLE001
            pass
        return 0


def _run_guarded(request_text: str) -> int:
    try:
        request = json.loads(request_text)
    except json.JSONDecodeError:
        _fail("", "invalid-request", "The request was not valid JSON.")
        return 0
    request_id = str(request.get("requestID", ""))
    if request.get("protocolRevision") != 2:
        _fail(request_id, "invalid-request", "Unsupported protocol revision.")
        return 0

    config_data = _read_optional_json(request.get("operationConfigurationPath")) or {}
    endpoint = str(config_data.get("endpoint") or "").rstrip("/")
    if not endpoint:
        _fail(request_id, "setup",
              "No Docling Serve endpoint is configured. Set it in Settings → Extraction.")
        return 0
    timeout_seconds = max(int(config_data.get("timeoutMilliseconds") or 600_000), 1) / 1000.0

    credentials_data = _read_optional_json(request.get("credentialFilePath")) or {}
    token = str((credentials_data.get("credentials") or {}).get("api-token") or "")
    if token and not _token_allowed_for(endpoint):
        _fail(request_id, "setup",
              "Refusing to send the API token over a non-HTTPS, non-loopback endpoint.")
        return 0

    input_path = Path(str(request.get("inputPath", "")))
    output_path = Path(str(request.get("outputPath", "")))
    if not input_path.is_file():
        _fail(request_id, "invalid-request", "The input file is missing.")
        return 0
    # The host deletes the credential file on every terminal path; deleting
    # it here too closes the window early (security review L-14).
    credential_path = request.get("credentialFilePath")
    if credential_path:
        try:
            Path(str(credential_path)).unlink()
        except OSError:
            pass

    _emit({"kind": "progress", "payload": {
        "requestID": request_id, "message": "Uploading to Docling Serve"}})

    boundary = "wiki-extractor-" + uuid.uuid4().hex
    file_bytes = input_path.read_bytes()
    filename = _sanitize_filename(str(request.get("originalFilename") or "source.pdf"))
    mime_type = mimetypes.guess_type(filename)[0] or "application/pdf"
    # The established Docling Serve wire contract (mirroring the host's
    # DoclingServeClient): scalar form fields `to_formats=md` and
    # `from_formats=pdf` BEFORE the file part, and the Markdown is returned
    # as `document.md_content`.
    scalar_parts = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="to_formats"\r\n\r\n'
        "md\r\n"
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="from_formats"\r\n\r\n'
        "pdf\r\n"
    )
    file_part = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="files"; filename="{filename}"\r\n'
        f"Content-Type: {mime_type}\r\n\r\n"
    ).encode("utf-8") + file_bytes + f"\r\n--{boundary}--\r\n".encode("utf-8")
    part = scalar_parts.encode("utf-8") + file_part

    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    if token:
        # urllib raises ValueError (echoing the value) for control characters
        # in header values; validate first so the token can never reach a
        # traceback (security review MEDIUM-5).
        if any(ord(character) < 32 or ord(character) == 127 for character in token):
            _fail(request_id, "setup",
                  "The stored token contains control characters and cannot be used.")
            return 0
        headers["X-Api-Key"] = token

    http_request = urllib.request.Request(
        endpoint + "/v1/convert/file", data=part, headers=headers, method="POST")
    try:
        with _OPENER.open(http_request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            # Redirects are blocked so the token can never follow them to
            # another origin (security review HIGH-2b).
            _fail(request_id, "setup",
                  "Docling Serve returned a redirect; redirects are not allowed.")
            return 0
        # Never include request headers or the token in the failure text.
        _fail(request_id, "extraction-failure",
              f"Docling Serve returned HTTP {error.code}.")
        return 0
    except urllib.error.URLError as error:
        _fail(request_id, "setup",
              f"Docling Serve is unreachable at the configured endpoint ({error.reason}).")
        return 0
    except TimeoutError:
        _fail(request_id, "timeout", "Docling Serve did not answer in time.")
        return 0

    document = payload.get("document") if isinstance(payload, dict) else None
    markdown = ""
    if isinstance(document, dict):
        # The single-file contract returns md_content; markdown_content is
        # accepted only as a documented compatibility alias.
        markdown = str(document.get("md_content")
                       or document.get("markdown_content") or "")
    elif isinstance(payload, str):
        markdown = payload
    if not markdown:
        _fail(request_id, "extraction-failure",
              "Docling Serve returned no Markdown content.")
        return 0

    encoded = markdown.encode("utf-8")
    if len(encoded) > _MAX_OUTPUT_BYTES:
        _fail(request_id, "output-limit", "The Markdown result exceeds the host limit.")
        return 0
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(encoded)
    _emit({
        "kind": "result",
        "payload": {
            "requestID": request_id,
            "outputPath": str(request.get("outputPath", "")),
            "markdownByteCount": len(encoded),
            "warnings": [],
        },
    })
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.stdin.read()))
