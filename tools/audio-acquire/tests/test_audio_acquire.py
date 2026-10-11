"""Protocol revision 5 (fetcher) tests for the audio-acquire package.

Run from the tools/audio-acquire directory:
    mise exec -- uv run pytest tests/test_audio_acquire.py -v

All yt-dlp behavior is mocked — no network access required. Failure
messages are fixed strings: these tests double as the redaction contract,
asserting the source URL, the signed media URL, upstream error text, and
paths never reach a frame or stderr.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from conftest import (
    FTYP_HEADER,
    REQUEST_ID,
    MockYoutubeDL,
    build_request,
    valid_metadata,
)

# ── Helpers ────────────────────────────────────────────────────────────


def run(audio: Any, request: dict[str, Any]) -> tuple[int, list[dict[str, Any]]]:
    """One protocol run over an in-memory stream."""
    import io

    stream = io.StringIO()
    code = audio.run_extractor_protocol(json.dumps(request), out_stream=stream)
    frames = [json.loads(line) for line in stream.getvalue().splitlines() if line]
    return code, frames


def patched_metadata(audio: Any, metadata: dict[str, Any]) -> None:
    MockYoutubeDL.extract_result = metadata
    MockYoutubeDL.extract_raises = None


@pytest.fixture(autouse=True)
def _reset_mock(audio: Any) -> Any:  # noqa: ARG001
    MockYoutubeDL.extract_result = {}
    MockYoutubeDL.extract_raises = None
    yield
    MockYoutubeDL.extract_result = {}
    MockYoutubeDL.extract_raises = None


@pytest.fixture(autouse=True)
def _operation_root(tmp_path: Path, monkeypatch: Any) -> None:
    """The host runs the package with its CWD at the operation root."""
    monkeypatch.chdir(tmp_path)


# ── Request validation ─────────────────────────────────────────────────


class TestRequestValidation:
    def test_rejects_wrong_protocol_revision(self, audio: Any) -> None:
        request = build_request()
        request["protocolRevision"] = 3
        code, frames = run(audio, request)
        assert code == 0
        assert frames[-1]["kind"] == "failure"
        assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_rejects_extractor_role(self, audio: Any) -> None:
        request = build_request()
        request["role"] = "extractor"
        code, frames = run(audio, request)
        assert frames[-1]["kind"] == "failure"
        assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_rejects_wrong_claimed_mime(self, audio: Any) -> None:
        request = build_request()
        request["mimeType"] = "video/youtube"
        code, frames = run(audio, request)
        assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_rejects_kind_and_staged_input(self, audio: Any) -> None:
        for extra in ({"kind": "audio-transcript"}, {"inputTransport": "remote-url"}, {"inputPath": "input/x"}):
            request = build_request()
            request.update(extra)
            code, frames = run(audio, request)
            assert frames[-1]["kind"] == "failure"
            assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_rejects_non_youtube_source_url(self, audio: Any) -> None:
        request = build_request()
        request["remoteURL"] = "https://evil.example/watch?v=dQw4w9WgXcQ"
        code, frames = run(audio, request)
        assert frames[-1]["payload"]["cause"] == "unsupported-input"
        # The URL is never echoed back.
        assert "evil.example" not in json.dumps(frames)

    def test_rejects_traversal_output_path(self, audio: Any) -> None:
        for bad in ("../escape", "/absolute", "a/../b", "a//b", ""):
            request = build_request(output_path=bad)
            code, frames = run(audio, request)
            assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_rejects_missing_deadline(self, audio: Any) -> None:
        request = build_request()
        del request["deadlineMillisecondsSince1970"]
        code, frames = run(audio, request)
        assert frames[-1]["payload"]["cause"] == "invalid-request"


# ── Success path ───────────────────────────────────────────────────────


class TestSuccess:
    def test_publishes_source_bytes_result(
        self, audio: Any, tmp_path: Path, monkeypatch: Any
    ) -> None:
        media_url = "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback?id=1"
        patched_metadata(audio, valid_metadata(media_url))
        payload = FTYP_HEADER + b"m" * 4096
        monkeypatch.setattr(
            audio, "_fetch_media_bytes", lambda *_a, **_k: payload
        )

        code, frames = run(audio, build_request())
        assert code == 0
        kinds = [frame["kind"] for frame in frames]
        assert kinds[-1] == "result"
        assert frames[-1]["payload"]["requestID"] == REQUEST_ID
        assert frames[-1]["payload"]["resultType"] == "source-bytes"
        assert frames[-1]["payload"]["resultMIMEType"] == "audio/mp4"
        assert frames[-1]["payload"]["markdownByteCount"] == len(payload)
        published = Path(frames[-1]["payload"]["outputPath"])
        assert published.read_bytes() == payload

        # The frame carries no URL, no token, and no media bytes.
        serialized = json.dumps(frames)
        assert "googlevideo" not in serialized
        assert "videoplayback" not in serialized

    def test_best_validated_m4a_is_selected(self, audio: Any) -> None:
        metadata = valid_metadata()
        best = audio.select_audio_format(metadata)
        assert best["format_id"] == "140"  # highest abr among validated m4a

        # format 140 fallback: when the highest-bitrate pick lacks a URL,
        # the pinned format id is the explicit fallback.
        metadata["formats"][2]["abr"] = 256.0  # format 139 wins the bitrate
        metadata["formats"][2]["url"] = None
        fallback = audio.select_audio_format(metadata)
        assert fallback["format_id"] == "140"

    def test_rejects_video_or_opus_only_metadata(self, audio: Any) -> None:
        metadata = {
            "duration": 600,
            "formats": [
                {"format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a"},
                {"format_id": "251", "ext": "webm", "vcodec": "none", "acodec": "opus", "url": "https://x.googlevideo.com/a"},
            ],
        }
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio.select_audio_format(metadata)
        assert excinfo.value.cause == "unsupported-input"


# ── Failure matrix ─────────────────────────────────────────────────────


class TestFailureMatrix:
    def test_metadata_failure_is_typed(self, audio: Any) -> None:
        MockYoutubeDL.extract_raises = RuntimeError("boom https://secret")
        code, frames = run(audio, build_request())
        assert frames[-1]["kind"] == "failure"
        assert frames[-1]["payload"]["cause"] == "extraction-failure"
        assert frames[-1]["payload"]["message"] == (
            "video metadata could not be retrieved"
        )
        # Upstream text is never framed.
        assert "secret" not in json.dumps(frames)

    def test_missing_duration_rejected(self, audio: Any) -> None:
        patched_metadata(audio, {"duration": None, "formats": valid_metadata()["formats"]})
        code, frames = run(audio, build_request())
        assert frames[-1]["payload"]["cause"] == "unsupported-input"

    def test_overlong_duration_rejected(self, audio: Any) -> None:
        metadata = valid_metadata()
        metadata["duration"] = 7201
        patched_metadata(audio, metadata)
        code, frames = run(audio, build_request())
        assert frames[-1]["payload"]["cause"] == "unsupported-input"

    def test_no_m4a_format_rejected(self, audio: Any) -> None:
        metadata = {"duration": 600, "formats": []}
        patched_metadata(audio, metadata)
        code, frames = run(audio, build_request())
        assert frames[-1]["payload"]["cause"] == "unsupported-input"

    def test_oversized_download_is_output_limit(
        self, audio: Any, monkeypatch: Any
    ) -> None:
        patched_metadata(audio, valid_metadata())

        def oversized(*_a: Any, **_k: Any) -> bytes:
            raise audio.ProtocolFailure("output-limit", "the audio stream exceeds the size limit")

        monkeypatch.setattr(audio, "_fetch_media_bytes", oversized)
        code, frames = run(audio, build_request())
        assert frames[-1]["payload"]["cause"] == "output-limit"

    def test_non_m4a_payload_rejected(self, audio: Any, monkeypatch: Any) -> None:
        patched_metadata(audio, valid_metadata())
        monkeypatch.setattr(audio, "_fetch_media_bytes", lambda *_a, **_k: b"<html>403</html>")
        code, frames = run(audio, build_request())
        assert frames[-1]["payload"]["cause"] == "extraction-failure"
        # The upstream body is never framed.
        assert "<html>" not in json.dumps(frames)

    def test_deadline_during_serving(self, audio: Any, monkeypatch: Any) -> None:
        patched_metadata(audio, valid_metadata())
        monkeypatch.setattr(
            audio, "_deadline_passed", lambda _deadline: True
        )
        code, frames = run(audio, build_request())
        assert frames[-1]["payload"]["cause"] == "timeout"

    def test_unexpected_defect_still_emits_one_frame(
        self, audio: Any, monkeypatch: Any
    ) -> None:
        patched_metadata(audio, valid_metadata())

        def explode(*_a: Any, **_k: Any) -> bytes:
            raise ValueError("internal https://leak")

        monkeypatch.setattr(audio, "_fetch_media_bytes", explode)
        code, frames = run(audio, build_request())
        assert len([f for f in frames if f["kind"] == "failure"]) == 1
        assert frames[-1]["payload"]["message"] == "audio acquisition failed"
        assert "leak" not in json.dumps(frames)


# ── Auxiliary runtime grant shape ──────────────────────────────────────


class TestBunPathReading:
    def test_reads_reviewed_shape(self, audio: Any, tmp_path: Path) -> None:
        config = tmp_path / "config.json"
        config.write_text(
            json.dumps(
                {
                    "kind": "reviewed-audio-acquire-bun-runtime",
                    "executablePath": "/usr/local/bin/bun",
                }
            ),
            encoding="utf-8",
        )
        request = build_request()
        request["operationConfigurationPath"] = "config.json"
        assert audio._read_bun_path(request) == "/usr/local/bin/bun"

    def test_rejects_other_kinds_and_bad_paths(self, audio: Any, tmp_path: Path) -> None:
        config = tmp_path / "config.json"
        # The caption package's grant kind is NOT this package's grant.
        config.write_text(
            json.dumps(
                {"kind": "reviewed-youtube-bun-runtime", "executablePath": "/usr/local/bin/bun"}
            ),
            encoding="utf-8",
        )
        request = build_request()
        request["operationConfigurationPath"] = "config.json"
        assert audio._read_bun_path(request) is None

        traversal = tmp_path / "config.json"
        traversal.write_text("{}", encoding="utf-8")
        request["operationConfigurationPath"] = "../config.json"
        assert audio._read_bun_path(request) is None
        request["operationConfigurationPath"] = "/etc/passwd"
        assert audio._read_bun_path(request) is None


# ── Manifest parity ────────────────────────────────────────────────────


class TestManifestParity:
    """The package-owned bounds must equal or tighten the manifest limits."""

    MANIFEST_PATH = (
        Path(__file__).resolve().parents[3]
        / "ExtractorPackages"
        / "AudioAcquire"
        / "manifest.json"
    )

    def test_manifest_matches_package_bounds(self) -> None:
        assert self.MANIFEST_PATH.exists(), (
            f"generated AudioAcquire manifest missing at {self.MANIFEST_PATH}"
        )
        manifest = json.loads(self.MANIFEST_PATH.read_text(encoding="utf-8"))

        assert manifest["packageID"] == "org.selfdrivingwiki.audio-acquire"
        assert manifest["version"] == "1.0.0"
        assert manifest["protocolRevision"] == 5
        assert manifest["manifestRevision"] == 4
        assert manifest["capabilities"] == ["network", "shared-runtime-cache"]

        registration = manifest["registrations"][0]
        assert registration["id"] == "audio"
        assert "kinds" not in registration
        assert registration["role"] == "fetcher"
        assert registration["mimeTypes"] == ["audio/x-wiki-audio-acquire"]
        assert manifest["launch"] == {
            "mode": "runtime",
            "command": "uv",
            "arguments": ["run", "--script"],
        }

        limits = manifest["limits"]
        assert limits["maximumInputByteCount"] == 1_048_576
        # The output bound must stay ABOVE the download bound: a full
        # acquisition is publishable, and the package's own 120 MiB cap is
        # the tighter effective limit.
        assert limits["maximumMarkdownOutputByteCount"] == 134_217_728
        assert 120 * 1024 * 1024 < limits["maximumMarkdownOutputByteCount"]
        assert limits["maximumDurationMilliseconds"] == 1_800_000
        assert limits["maximumProgressEventCount"] == 64
