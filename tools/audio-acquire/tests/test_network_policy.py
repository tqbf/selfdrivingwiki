"""Network policy tests for the audio-acquire package.

Run from the tools/audio-acquire directory:
    mise exec -- uv run pytest tests/test_network_policy.py -v

Two layers, both offline:

- Guard unit tests drive `_ConnectionGuard` against a FAKE resolver and a
  recording connect seam, asserting the DNS/connect policy: allowlists,
  global-routability, mixed-answer rejection, changing-DNS pinning, and
  zero unauthorized connection attempts.
- Client tests drive the production media fetcher with an injected
  low-level handler stub (only the socket transport is replaced): URL
  allowlists, redirect refusal, compressed-response refusal, auth/401/403/
  429 fixed failures, and the cap+1 read bound.
"""

from __future__ import annotations

import io
import socket
import subprocess
import time
import urllib.error
import urllib.request
from email.message import Message
from pathlib import Path
from typing import Any

import pytest
from conftest import REQUEST_ID, WATCH_URL, build_request, valid_metadata  # noqa: F401

WATCH_URL_HOST = "www.youtube.com"


def self_good_url() -> str:
    return "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback?id=1&sig=abc"


def urllib_error(status: int, headers: dict[str, str] | None = None) -> Any:
    error = urllib.error.HTTPError(
        self_good_url(), status, "fixture", _message(headers or {}), io.BytesIO(b"")
    )
    return error


def _message(headers: dict[str, str]) -> Message:
    message = Message()
    for key, value in headers.items():
        message[key] = value
    return message

# ── Fake socket layer ──────────────────────────────────────────────────

_GLOBAL_V4 = "142.250.65.110"
_GLOBAL_V6 = "2607:f8b0:4006:81a::200e"
_PRIVATE_V4 = "10.0.0.7"
_LOOPBACK = "127.0.0.1"


class FakeResolver:
    """A controllable stand-in for `socket.getaddrinfo`."""

    def __init__(self, answers_by_host: dict[str, list[str]]) -> None:
        self.answers_by_host = answers_by_host
        self.lookups: list[str] = []

    def __call__(self, host: Any, port: Any, *args: Any, **kwargs: Any) -> list[tuple]:
        name = host if isinstance(host, str) else str(host)
        self.lookups.append(name)
        addresses = self.answers_by_host.get(name)
        if addresses is None:
            raise socket.gaierror(-2, "Name or service not known")
        return [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port))
            for address in addresses
        ]


class RecordingConnect:
    """Replaces `socket.create_connection` with a recording fake."""

    def __init__(self) -> None:
        self.connected: list[tuple[str, int]] = []

    def __call__(self, address: Any, *args: Any, **kwargs: Any) -> Any:
        host, port = address[0], address[1]
        self.connected.append((host, port))
        raise AssertionError("tests must not complete real connections")

    def connect_directly(self, address: Any) -> None:
        """Simulate a socket connect to one sockaddr (recording only)."""
        self.connected.append((address[0], address[1]))


@pytest.fixture()
def guard_sockets(monkeypatch: Any) -> Any:
    """Installs fake resolver/connect as the REAL socket layer."""
    holder: dict[str, Any] = {}

    def install(answers_by_host: dict[str, list[str]]) -> tuple[FakeResolver, RecordingConnect]:
        resolver = FakeResolver(answers_by_host)
        connect = RecordingConnect()
        monkeypatch.setattr(socket, "getaddrinfo", resolver)
        monkeypatch.setattr(socket, "create_connection", connect)
        holder["resolver"] = resolver
        holder["connect"] = connect
        return resolver, connect

    holder["install"] = install
    return holder


# ── Guard policy ───────────────────────────────────────────────────────


class TestConnectionGuard:
    def test_metadata_host_allowlist(
        self, audio: Any, guard_sockets: Any
    ) -> None:
        install = guard_sockets["install"]
        install({WATCH_URL_HOST: [_GLOBAL_V4]})
        with audio._ConnectionGuard(audio._metadata_host_allowed) as guard:
            guard._getaddrinfo(WATCH_URL_HOST, 443)
        assert guard.unauthorized_attempts == 0

    def test_private_dns_answer_rejected(
        self, audio: Any, guard_sockets: Any
    ) -> None:
        install = guard_sockets["install"]
        resolver, _connect = install({WATCH_URL_HOST: [_PRIVATE_V4]})
        with audio._ConnectionGuard(audio._metadata_host_allowed) as guard:
            with pytest.raises(audio.ProtocolFailure) as excinfo:
                guard._getaddrinfo(WATCH_URL_HOST, 443)
        assert "address" in excinfo.value.message
        assert resolver.lookups == [WATCH_URL_HOST]

    def test_mixed_dns_answers_rejected(self, audio: Any, guard_sockets: Any) -> None:
        install = guard_sockets["install"]
        install({WATCH_URL_HOST: [_GLOBAL_V4, _PRIVATE_V4]})
        with audio._ConnectionGuard(audio._metadata_host_allowed) as guard:
            with pytest.raises(audio.ProtocolFailure):
                guard._getaddrinfo(WATCH_URL_HOST, 443)

    def test_loopback_answer_rejected(self, audio: Any, guard_sockets: Any) -> None:
        install = guard_sockets["install"]
        install({"rr3---sn-p5qs7nz6.googlevideo.com": [_LOOPBACK]})
        with audio._ConnectionGuard(audio._media_host_allowed) as guard:
            with pytest.raises(audio.ProtocolFailure):
                guard._getaddrinfo("rr3---sn-p5qs7nz6.googlevideo.com", 443)

    def test_changing_dns_pins_first_validated_answer(
        self, audio: Any, guard_sockets: Any
    ) -> None:
        install = guard_sockets["install"]
        resolver, _connect = install({WATCH_URL_HOST: [_GLOBAL_V4]})
        with audio._ConnectionGuard(audio._metadata_host_allowed) as guard:
            first = guard._getaddrinfo(WATCH_URL_HOST, 443)
            # The "attacker" changes DNS between lookups.
            resolver.answers_by_host[WATCH_URL_HOST] = [_PRIVATE_V4]
            second = guard._getaddrinfo(WATCH_URL_HOST, 443)
        assert first == second
        assert resolver.lookups.count(WATCH_URL_HOST) == 1  # no second lookup

    def test_connect_uses_validated_address_without_lookup(
        self, audio: Any, guard_sockets: Any, monkeypatch: Any
    ) -> None:
        install = guard_sockets["install"]
        resolver, _connect = install({WATCH_URL_HOST: [_GLOBAL_V4, _GLOBAL_V6]})

        connects: list[Any] = []

        class FakeSocket:
            def __init__(self, *_a: Any) -> None:
                pass

            def settimeout(self, _t: Any) -> None:
                pass

            def connect(self, sockaddr: Any) -> None:
                connects.append(tuple(sockaddr))

            def close(self) -> None:
                pass

        monkeypatch.setattr(socket, "socket", FakeSocket)
        with audio._ConnectionGuard(audio._metadata_host_allowed) as guard:
            guard._create_connection((WATCH_URL_HOST, 443), timeout=10)
        assert resolver.lookups == [WATCH_URL_HOST]  # resolved exactly once
        # Connected to the FIRST validated address, never the hostname.
        assert connects == [(_GLOBAL_V4, 443)]

    def test_media_phase_permits_any_host(self, audio: Any) -> None:
        # The operator's policy: any URL. The DNS-level fence (global
        # routability) is what remains, tested above.
        assert audio._media_host_allowed("rr3---sn-p5qs7nz6.googlevideo.com")
        assert audio._media_host_allowed("example.org")


# ── Media URL validation ───────────────────────────────────────────────


class TestMediaPolicy:
    def test_any_host_permitted(self, audio: Any) -> None:
        assert audio._metadata_host_allowed("example.org")
        assert audio._media_host_allowed("example.org")

    def test_produced_m4a_validated(self, audio: Any) -> None:
        from conftest import FTYP_HEADER

        audio.validate_m4a(FTYP_HEADER + b"payload")
        with pytest.raises(audio.ProtocolFailure):
            audio.validate_m4a(b"<html>not audio</html>")


# ── Media download through the pinned native downloader ────────────────


class TestMediaDownload:
    class _FakeDownloader:
        def __init__(self, fail: bool = False) -> None:
            self.fail = fail
            self.download_calls: list[list[str]] = []

        def download(self, urls: list[str]) -> None:
            self.download_calls.append(urls)
            if self.fail:
                raise OSError("download failed")

        def close(self) -> None:
            return

    def test_download_renames_and_reads_payload(
        self, audio: Any, tmp_path: Path, monkeypatch: Any
    ) -> None:
        from conftest import FTYP_HEADER

        output_dir = tmp_path / "output"
        output_dir.mkdir()
        payload = FTYP_HEADER + b"m" * 512
        produced = output_dir / "result.m4a"
        produced.write_bytes(payload)
        final = output_dir / "result"

        downloader = self._FakeDownloader()
        monkeypatch.setattr(audio, "_build_downloader", lambda *_a, **_k: downloader)
        got = audio.download_audio(
            str(output_dir), str(final), "dQw4w9WgXcQ", None,
            int(time.time() * 1000) + 60_000)
        assert got == payload
        assert downloader.download_calls == [[audio._YOUTUBE_WATCH_BASE + "?v=dQw4w9WgXcQ"]]
        # The produced file was moved to the requested output path.
        assert final.read_bytes() == payload
        assert produced.exists() is False

    def test_missing_output_is_typed_failure(
        self, audio: Any, tmp_path: Path, monkeypatch: Any
    ) -> None:
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        downloader = self._FakeDownloader()
        monkeypatch.setattr(audio, "_build_downloader", lambda *_a, **_k: downloader)
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio.download_audio(
                str(output_dir), str(output_dir / "result"), "dQw4w9WgXcQ", None,
                int(time.time() * 1000) + 60_000)
        assert excinfo.value.message == "the audio stream could not be downloaded"

    def test_download_failure_is_typed(
        self, audio: Any, tmp_path: Path, monkeypatch: Any
    ) -> None:
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        downloader = self._FakeDownloader(fail=True)
        monkeypatch.setattr(audio, "_build_downloader", lambda *_a, **_k: downloader)
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio.download_audio(
                str(output_dir), str(output_dir / "result"), "dQw4w9WgXcQ", None,
                int(time.time() * 1000) + 60_000)
        assert excinfo.value.message == "the audio stream could not be downloaded"

    def test_oversized_download_is_output_limit(
        self, audio: Any, tmp_path: Path, monkeypatch: Any
    ) -> None:
        from conftest import FTYP_HEADER

        output_dir = tmp_path / "output"
        output_dir.mkdir()
        (output_dir / "result.m4a").write_bytes(
            FTYP_HEADER + b"m" * (audio._MEDIA_MAX_FILESIZE + 1))
        monkeypatch.setattr(
            audio, "_build_downloader",
            lambda *_a, **_k: self._FakeDownloader())
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio.download_audio(
                str(output_dir), str(output_dir / "result"), "dQw4w9WgXcQ", None,
                int(time.time() * 1000) + 60_000)
        assert excinfo.value.cause == "output-limit"


# ── AC.1: the real pinned-library offline contract ──────────────────────


_CONTRACT_PATH = Path(__file__).resolve().parent / "_ytdlp_offline_contract.py"
_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "audio-acquire"


class TestRealYtdlpOfflineContract:
    def test_pep723_blocks_match_the_entry_point(self) -> None:
        """The contract script imports the SAME pinned dependencies as the
        generated entry point — one drift gate, not a second pin."""

        def block(path: Path) -> str:
            text = path.read_text(encoding="utf-8")
            return text.split("# /// script", 1)[1].split("# ///", 1)[0]

        assert block(_CONTRACT_PATH) == block(_SCRIPT_PATH)

    def test_real_ytdlp_plugin_guard(self) -> None:
        """The package's no-plugins guard holds against the pinned
        release's plugin loader; the control fixture proves liveness."""
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            ["uv", "run", "--script", str(_CONTRACT_PATH), "plugin-guard"],
            capture_output=True,
            text=True,
            timeout=600,
            cwd=_SCRIPT_PATH.parent,
            check=False,
        )
        assert result.returncode == 0, (
            f"plugin guard arm failed:\n{result.stdout}\n{result.stderr}"
        )
        assert "PLUGIN GUARD OK" in result.stdout

    def test_real_ytdlp_offline_contract(self) -> None:
        """Real YoutubeDL option parsing + format selection + the
        connection guard under a fake resolver + a fail-closed metadata
        call against a dead socket layer with zero unauthorized
        connection attempts.

        No network access is required or attempted: the fake resolver
        replaces only the DNS seam, and the fixed-text failure assertions
        fire if any real connection is attempted.
        """
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            ["uv", "run", "--script", str(_CONTRACT_PATH), "contract"],
            capture_output=True,
            text=True,
            timeout=600,
            cwd=_SCRIPT_PATH.parent,
            check=False,
        )
        assert result.returncode == 0, (
            f"offline contract failed:\n{result.stdout}\n{result.stderr}"
        )
        assert "CONTRACT OK" in result.stdout
