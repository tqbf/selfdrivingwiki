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

        # A different host is refused BEFORE any DNS query is issued.
        resolver, _connect = install({WATCH_URL_HOST: [_GLOBAL_V4]})
        with audio._ConnectionGuard(audio._metadata_host_allowed) as guard:
            with pytest.raises(audio.ProtocolFailure) as excinfo:
                guard._getaddrinfo("evil.example", 443)
        assert "host" in excinfo.value.message
        assert resolver.lookups == []
        assert guard.unauthorized_attempts == 1

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

    def test_media_suffix_allowlist(self, audio: Any) -> None:
        assert audio._media_host_allowed("rr3---sn-p5qs7nz6.googlevideo.com")
        assert audio._media_host_allowed("a.b.googlevideo.com")
        # The bare suffix is NOT a valid host: one or more labels must
        # precede it.
        assert audio._media_host_allowed("googlevideo.com") is False
        assert audio._media_host_allowed(".googlevideo.com") is False
        assert audio._media_host_allowed("evil-googlevideo.com") is False
        assert audio._media_host_allowed("googlevideo.com.evil.example") is False


# ── Media URL validation ───────────────────────────────────────────────


class TestMediaURLValidation:
    GOOD = "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback?id=1&sig=abc"

    def test_accepts_signed_media_url(self, audio: Any) -> None:
        assert audio._validate_media_url(self.GOOD) == self.GOOD

    def test_rejects_every_other_shape(self, audio: Any) -> None:
        for bad in (
            "http://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback",
            "https://evil.example/videoplayback",
            "https://googlevideo.com/videoplayback",
            "https://www.youtube.com/videoplayback",
            "https://rr3---sn-p5qs7nz6.googlevideo.com:8443/videoplayback",
            "https://user:pass@rr3---sn-p5qs7nz6.googlevideo.com/videoplayback",
            "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback#fragment",
            "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback#",
            "https://rr3---sn-p5qs7nz6.googlevideo.com/" + "a" * 20_000,
        ):
            with pytest.raises(audio.ProtocolFailure) as excinfo:
                audio._validate_media_url(bad)
            assert excinfo.value.message == "the media location is not allowed"


# ── Media fetch through the production opener ──────────────────────────


class _FakeResponse:
    """The minimum urllib response surface the fetch path uses."""

    def __init__(
        self,
        status: int,
        body: bytes = b"",
        headers: dict[str, str] | None = None,
    ) -> None:
        self.status = status
        self.code = status
        self.msg = "fixture"
        self.headers = Message()
        for key, value in (headers or {}).items():
            self.headers[key] = value
        self._body = body
        self.closed = False

    def info(self) -> Message:
        return self.headers

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def close(self) -> None:
        self.closed = True

    def read(self, size: int = -1) -> bytes:
        if size < 0 or size >= len(self._body):
            body, self._body = self._body, b""
            return body
        body, self._body = self._body[:size], self._body[size:]
        return body


class _HandlerStub(urllib.request.HTTPSHandler):
    """Replaces ONLY the low-level HTTPS transport; no socket is opened."""

    def __init__(self, responses: list[Any]) -> None:
        super().__init__()
        self.responses = list(responses)
        self.requests: list[Any] = []

    def https_open(self, req: Any) -> Any:
        self.requests.append(req)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    def http_open(self, req: Any) -> Any:
        # Never reached by the production fetcher (https only); present so
        # a scheme mistake cannot fall through to a real connection.
        self.requests.append(req)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def _deadline(audio: Any, seconds: int = 600) -> int:
    import time

    return int(time.time() * 1000) + seconds * 1000


def self_good_url() -> str:
    return "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback?id=1&sig=abc"


class TestMediaFetch:
    def test_success_reads_exactly_the_body(self, audio: Any) -> None:
        from conftest import FTYP_HEADER

        body = FTYP_HEADER + b"audio" * 100
        stub = _HandlerStub([_FakeResponse(200, body)])
        payload = audio._fetch_media_bytes(
            self_good_url(), 200 * 1024 * 1024, _deadline(audio), https_handler=stub
        )
        assert payload == body
        request = stub.requests[0]
        assert request.get_header("Accept-encoding") == "identity"

    def test_redirect_is_refused_not_followed(self, audio: Any) -> None:
        redirect = urllib_error(302, {"Location": "https://evil.example/x"})
        stub = _HandlerStub([redirect])
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio._fetch_media_bytes(
                self_good_url(), 1024, _deadline(audio), https_handler=stub
            )
        assert excinfo.value.message == "the audio stream could not be downloaded"
        assert len(stub.requests) == 1  # never followed

    def test_401_403_429_are_typed_rejections(self, audio: Any) -> None:
        for status in (401, 403, 429):
            stub = _HandlerStub([urllib_error(status)])
            with pytest.raises(audio.ProtocolFailure) as excinfo:
                audio._fetch_media_bytes(
                    self_good_url(), 1024, _deadline(audio), https_handler=stub
                )
            assert excinfo.value.message == "the media server rejected the request"

    def test_compressed_response_refused(self, audio: Any) -> None:
        stub = _HandlerStub(
            [_FakeResponse(200, b"gz", headers={"Content-Encoding": "gzip"})]
        )
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio._fetch_media_bytes(
                self_good_url(), 1024, _deadline(audio), https_handler=stub
            )
        assert excinfo.value.message == "the media response used an unsupported encoding"

    def test_oversized_stream_hits_cap_plus_one(self, audio: Any) -> None:
        cap = 1024
        body = b"a" * (cap + 64)
        stub = _HandlerStub([_FakeResponse(200, body)])
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio._fetch_media_bytes(
                self_good_url(), cap, _deadline(audio), https_handler=stub
            )
        assert excinfo.value.cause == "output-limit"

    def test_transport_error_is_typed(self, audio: Any) -> None:
        stub = _HandlerStub([OSError("connection reset https://secret")])
        with pytest.raises(audio.ProtocolFailure) as excinfo:
            audio._fetch_media_bytes(
                self_good_url(), 1024, _deadline(audio), https_handler=stub
            )
        assert excinfo.value.message == "the audio stream could not be downloaded"


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
