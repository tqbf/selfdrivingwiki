"""Unit tests for the zotero package protocol entry point.

The reviewed package serves ONE revision-4 `remote-url` request per process:
a JSON request object on stdin, JSON Lines frames on stdout, and the
attachment bytes at the requested output path. These tests pin request
validation, credential handling, link-mode rejection, HTTP error mapping,
result shapes (markdown vs bytes), frame emission, and the output limit.
All HTTP is mocked; no test touches the network.

Run from the tools/zotero directory:
    uv run pytest tests/test_package_protocol.py -v
"""

from __future__ import annotations

import io
import json
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest
import requests

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "zotero"
assert _SCRIPT_PATH.exists(), f"zotero script not found at {_SCRIPT_PATH}"

_loader = SourceFileLoader("zotero", str(_SCRIPT_PATH))
_zotero = _loader.load_module()

_REQUEST_ID = "4f25e76a-be09-467f-b71e-68c02da4d16a"
_ATTACHMENT_KEY = "ABCD1234"
_PARENT_KEY = "PARENT01"
_API_KEY = "test-api-key-value"
_FILE_URL = f"https://api.zotero.org/users/12345/items/{_ATTACHMENT_KEY}/file"

_PDF_BYTES = b"%PDF-1.4\n...fixture..."


def _request(**overrides: Any) -> dict[str, Any]:
    request: dict[str, Any] = {
        "requestID": _REQUEST_ID,
        "protocolRevision": 4,
        "kind": "zotero",
        "mimeType": "application/zotero",
        "originalFilename": _ATTACHMENT_KEY,
        "inputTransport": "remote-url",
        "remoteURL": _FILE_URL,
        "outputPath": "output/result.md",
        "deadlineMillisecondsSince1970": 9999999999999,
        "credentialFilePath": "credentials/input.json",
    }
    request.update(overrides)
    return request


@pytest.fixture(autouse=True)
def _relative_output_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Keep every write inside tmp: the default request outputPath is
    relative, and an unpatched write would pollute the working tree."""
    monkeypatch.chdir(tmp_path)
    return tmp_path


@pytest.fixture()
def credential_file(tmp_path: Path) -> Path:
    path = tmp_path / "credentials" / "input.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"credentials": {"zotero-api-key": _API_KEY}}))
    return path


class FakeResponse:
    def __init__(
        self,
        status_code: int = 200,
        json_data: Any = None,
        chunks: tuple[bytes, ...] = (),
    ) -> None:
        self.status_code = status_code
        self._json_data = json_data
        self._chunks = chunks

    def json(self) -> Any:
        if self._json_data is None:
            raise ValueError("no json body")
        return self._json_data

    def iter_content(self, chunk_size: int | None = None):  # noqa: ANN202
        yield from self._chunks


def _attachment_envelope(**data: Any) -> dict[str, Any]:
    return {"key": _ATTACHMENT_KEY, "version": 7, "data": {"key": _ATTACHMENT_KEY, **data}}


def _parent_envelope(**data: Any) -> dict[str, Any]:
    return {"key": _PARENT_KEY, "version": 3, "data": {"key": _PARENT_KEY, **data}}


def _fake_get(
    attachment: Any,
    parent: dict[str, Any] | None = None,
    file_chunks: tuple[bytes, ...] = (_PDF_BYTES,),
    file_status: int = 200,
    error: Exception | None = None,
    attachment_status: int = 200,
):
    calls: list[dict[str, Any]] = []

    def fake_get(url: str, headers=None, timeout=None, stream=False, **kwargs):  # noqa: ANN001, ANN202
        calls.append({"url": url, "headers": headers, "stream": stream, "timeout": timeout})
        if error is not None:
            raise error
        if url.endswith("/file"):
            return FakeResponse(file_status, chunks=file_chunks)
        if url.endswith(f"/items/{_PARENT_KEY}"):
            return FakeResponse(200 if parent is not None else 404, json_data=parent)
        return FakeResponse(attachment_status, json_data=attachment)

    return fake_get, calls


def _run(request: dict[str, Any] | str, fake_get) -> tuple[int, list[dict[str, Any]], str]:
    out = io.StringIO()
    request_text = request if isinstance(request, str) else json.dumps(request)
    with patch.object(_zotero.requests, "get", side_effect=fake_get):
        code = _zotero.run_extractor_protocol(
            request_text, out_stream=out, log_stream=io.StringIO()
        )
    frames = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    return code, frames, out.getvalue()


def _terminal(frames: list[dict[str, Any]]) -> dict[str, Any]:
    terminals = [frame for frame in frames if frame["kind"] in ("result", "failure")]
    assert len(terminals) == 1, f"expected exactly one terminal frame, got {frames}"
    return terminals[0]


# ── Happy paths ────────────────────────────────────────────────────────────


class TestMarkdownResult:
    def test_markdown_attachment_has_no_result_mime_type(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file",
            contentType="text/markdown",
            filename="notes.md",
            parentItem=_PARENT_KEY,
            title="Lecture notes",
        )
        parent = _parent_envelope(
            itemType="journalArticle",
            title="A Study of Tests",
            date="2024-05-01",
            creators=[{"creatorType": "author", "firstName": "Jane", "lastName": "Doe"}],
        )
        markdown = b"# Notes\n\nderived from Zotero\n"
        fake_get, calls = _fake_get(attachment, parent=parent, file_chunks=(markdown,))

        code, frames, raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)

        assert code == 0
        terminal = _terminal(frames)
        assert terminal["kind"] == "result"
        payload = terminal["payload"]
        assert payload["requestID"] == _REQUEST_ID
        assert payload["markdownByteCount"] == len(markdown)
        assert "resultMIMEType" not in payload
        assert payload["articleMetadata"] == {
            "title": "A Study of Tests",
            "author": "Doe, J.",
            "published": "2024-05-01",
            "identifier": _PARENT_KEY,
        }
        assert Path("output/result.md").read_bytes() == markdown
        # Frame budget: bounded progress events, one terminal, requestID
        # echoed on every frame.
        assert [frame["kind"] for frame in frames] == ["progress", "progress", "result"]
        assert all(frame["payload"]["requestID"] == _REQUEST_ID for frame in frames)
        # No URL or key material in any frame.
        assert _FILE_URL not in raw
        assert _API_KEY not in raw
        # The file request streamed and carried the API headers.
        file_calls = [call for call in calls if call["url"].endswith("/file")]
        assert len(file_calls) == 1
        assert file_calls[0]["stream"] is True
        assert file_calls[0]["headers"] == {
            "Zotero-API-Key": _API_KEY,
            "Zotero-API-Version": "3",
        }
        # Every API request carried the API headers.
        assert all(call["headers"]["Zotero-API-Version"] == "3" for call in calls)


class TestBytesResult:
    def test_pdf_attachment_carries_result_mime_type(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file",
            contentType="application/pdf",
            filename="paper.pdf",
            parentItem=_PARENT_KEY,
            title="paper.pdf",
        )
        fake_get, _ = _fake_get(attachment, parent=_parent_envelope(title="A Paper"))

        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)

        assert code == 0
        payload = _terminal(frames)["payload"]
        assert payload["resultMIMEType"] == "application/pdf"
        assert payload["markdownByteCount"] == len(_PDF_BYTES)
        assert Path("output/result.md").read_bytes() == _PDF_BYTES

    def test_html_attachment_via_filename_fallback(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file",
            filename="snapshot.html",
            parentItem=None,
        )
        fake_get, _ = _fake_get(attachment, parent=None, file_chunks=(b"<html></html>",))

        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)

        assert code == 0
        payload = _terminal(frames)["payload"]
        assert payload["resultMIMEType"] == "text/html"
        # No parent item: identifier falls back to the attachment key.
        assert payload["articleMetadata"]["identifier"] == _ATTACHMENT_KEY

    def test_markdown_via_filename_fallback(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file", filename="plain.md", parentItem=None
        )
        fake_get, _ = _fake_get(attachment, file_chunks=(b"hello",))

        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)

        assert code == 0
        payload = _terminal(frames)["payload"]
        assert "resultMIMEType" not in payload
        assert payload["markdownByteCount"] == 5


# ── Request validation ─────────────────────────────────────────────────────


class TestRequestValidation:
    @pytest.mark.parametrize(
        ("override", "cause"),
        [
            ({"protocolRevision": 3}, "invalid-request"),
            ({"kind": "podcast-transcript"}, "unsupported-input"),
            ({"inputTransport": "operation-file"}, "invalid-request"),
            ({"remoteURL": None}, "invalid-request"),
            ({"remoteURL": "https://api.zotero.org/users/1/items/ABCD1234"}, "invalid-request"),
            (
                {"remoteURL": "https://evil.example.com/users/1/items/ABCD1234/file"},
                "invalid-request",
            ),
            (
                {"remoteURL": "https://api.zotero.org/groups/1/items/ABCD1234/file"},
                "invalid-request",
            ),
            (
                {"remoteURL": "https://api.zotero.org/users/1/items/abcd1234/file"},
                "invalid-request",
            ),
            ({"outputPath": None}, "invalid-request"),
        ],
    )
    def test_typed_rejections(self, credential_file: Path, override: dict, cause: str) -> None:
        fake_get, _ = _fake_get(_attachment_envelope())
        request = _request(**override, credentialFilePath=str(credential_file))
        code, frames, _raw = _run(request, fake_get)
        assert code == 0
        terminal = _terminal(frames)
        assert terminal["kind"] == "failure"
        assert terminal["payload"]["cause"] == cause

    def test_malformed_json_exits_nonzero_without_frames(self) -> None:
        out = io.StringIO()
        code = _zotero.run_extractor_protocol(
            "{not json", out_stream=out, log_stream=io.StringIO()
        )
        assert code == 2
        assert out.getvalue() == ""

    def test_missing_request_id_exits_nonzero(self) -> None:
        out = io.StringIO()
        code = _zotero.run_extractor_protocol("{}", out_stream=out, log_stream=io.StringIO())
        assert code == 2
        assert out.getvalue() == ""


# ── Credentials ────────────────────────────────────────────────────────────


class TestCredentialHandling:
    @pytest.mark.parametrize("credential_path", [None, "", str(Path("absent/input.json"))])
    def test_missing_credential_is_invalid_request(
        self, credential_path: str | None
    ) -> None:
        fake_get, _ = _fake_get(_attachment_envelope())
        overrides = {"credentialFilePath": credential_path}
        code, frames, raw = _run(_request(**overrides), fake_get)
        assert code == 0
        terminal = _terminal(frames)
        assert terminal["kind"] == "failure"
        assert terminal["payload"]["cause"] == "invalid-request"
        assert "API key" in terminal["payload"]["message"]
        # No network call may happen without credentials: exactly one frame.
        assert len(frames) == 1

    def test_no_url_or_key_in_failure_messages(self, tmp_path: Path) -> None:
        path = tmp_path / "c.json"
        path.write_text(json.dumps({"credentials": {"other-key": "x"}}))
        fake_get, _ = _fake_get(_attachment_envelope())
        code, frames, raw = _run(_request(credentialFilePath=str(path)), fake_get)
        assert code == 0
        _terminal(frames)
        assert _FILE_URL not in raw
        assert _API_KEY not in raw


# ── Link modes and attachment types ────────────────────────────────────────


class TestLinkModesAndTypes:
    @pytest.mark.parametrize("link_mode", ["linked_file", "linked_url"])
    def test_linked_modes_are_unsupported_input(
        self, credential_file: Path, link_mode: str
    ) -> None:
        attachment = _attachment_envelope(linkMode=link_mode, url="/path/or/site")
        fake_get, _ = _fake_get(attachment)
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        terminal = _terminal(frames)
        assert terminal["kind"] == "failure"
        assert terminal["payload"]["cause"] == "unsupported-input"

    def test_unsupported_content_type_is_unsupported_input(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file", contentType="image/png", filename="pic.png"
        )
        fake_get, _ = _fake_get(attachment)
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        assert _terminal(frames)["payload"]["cause"] == "unsupported-input"

    def test_invalid_item_envelope_is_extraction_failure(self, credential_file: Path) -> None:
        fake_get, _ = _fake_get(["not", "an", "envelope"])
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        assert _terminal(frames)["payload"]["cause"] == "extraction-failure"


# ── HTTP and network error mapping ─────────────────────────────────────────


class TestHTTPErrorMapping:
    @pytest.mark.parametrize(
        ("status", "message_fragment"),
        [(403, "rejected the credentials"), (404, "not found"), (500, "returned an error")],
    )
    def test_status_mapping(
        self, credential_file: Path, status: int, message_fragment: str
    ) -> None:
        fake_get, _ = _fake_get(_attachment_envelope(), attachment_status=status)
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        terminal = _terminal(frames)
        assert terminal["kind"] == "failure"
        assert terminal["payload"]["cause"] == "extraction-failure"
        assert message_fragment in terminal["payload"]["message"]

    def test_transport_error_is_extraction_failure(self, credential_file: Path) -> None:
        fake_get, _ = _fake_get(
            _attachment_envelope(), error=requests.ConnectionError("boom")
        )
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        assert _terminal(frames)["payload"]["cause"] == "extraction-failure"

    def test_file_download_error_is_extraction_failure(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file", contentType="application/pdf", filename="a.pdf"
        )
        calls: list[str] = []

        def fake_get(url: str, headers=None, timeout=None, stream=False, **kwargs):  # noqa: ANN001, ANN202
            calls.append(url)
            if url.endswith("/file"):
                raise requests.ConnectionError("download failed")
            return FakeResponse(200, json_data=attachment)

        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        assert _terminal(frames)["payload"]["cause"] == "extraction-failure"

    def test_non200_file_download_is_extraction_failure(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file", contentType="application/pdf", filename="a.pdf"
        )
        fake_get, _ = _fake_get(attachment, file_status=502)
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        assert _terminal(frames)["payload"]["cause"] == "extraction-failure"


# ── Limits and deadline ────────────────────────────────────────────────────


class TestLimitsAndDeadline:
    def test_oversized_download_self_reports_output_limit(
        self, credential_file: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(_zotero, "MAX_OUTPUT_BYTES", 8)
        attachment = _attachment_envelope(
            linkMode="imported_file", contentType="application/pdf", filename="a.pdf"
        )
        fake_get, _ = _fake_get(attachment, file_chunks=(b"x" * 32,))
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        terminal = _terminal(frames)
        assert terminal["payload"]["cause"] == "output-limit"
        # No output file may be left behind.
        assert not Path("output/result.md").exists()

    def test_passed_deadline_self_reports_timeout(self, credential_file: Path) -> None:
        fake_get, calls = _fake_get(_attachment_envelope())
        request = _request(
            deadlineMillisecondsSince1970=1000, credentialFilePath=str(credential_file)
        )
        code, frames, _raw = _run(request, fake_get)
        assert code == 0
        assert _terminal(frames)["payload"]["cause"] == "timeout"
        assert calls == []  # the deadline failed before any network call


# ── Parent metadata degradation ────────────────────────────────────────────


class TestParentDegradation:
    def test_parent_fetch_failure_degrades_without_failing(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file",
            contentType="text/markdown",
            filename="n.md",
            parentItem=_PARENT_KEY,
            title="Attachment title",
        )
        fake_get, _ = _fake_get(attachment, parent=None, file_chunks=(b"# md",))
        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        payload = _terminal(frames)["payload"]
        assert payload["articleMetadata"] == {
            "title": "Attachment title",
            "identifier": _PARENT_KEY,
        }

    def test_parent_transport_failure_degrades_without_failing(self, credential_file: Path) -> None:
        attachment = _attachment_envelope(
            linkMode="imported_file",
            contentType="text/markdown",
            filename="n.md",
            parentItem=_PARENT_KEY,
            title="Attachment title",
        )
        calls: list[str] = []

        def fake_get(url: str, headers=None, timeout=None, stream=False, **kwargs):  # noqa: ANN001, ANN202
            calls.append(url)
            if url.endswith("/file"):
                return FakeResponse(200, chunks=(b"# md",))
            if url.endswith(f"/items/{_PARENT_KEY}"):
                raise requests.Timeout("slow")
            return FakeResponse(200, json_data=attachment)

        code, frames, _raw = _run(_request(credentialFilePath=str(credential_file)), fake_get)
        assert code == 0
        payload = _terminal(frames)["payload"]
        assert payload["articleMetadata"]["title"] == "Attachment title"
        assert payload["articleMetadata"]["identifier"] == _PARENT_KEY
