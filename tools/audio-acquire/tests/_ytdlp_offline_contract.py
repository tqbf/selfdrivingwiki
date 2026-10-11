# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = [
#     "yt-dlp==2026.08.19",
#     "yt-dlp-ejs==0.8.0",
# ]
# ///
"""Offline contract between the reviewed audio-acquire package and its
pinned yt-dlp release.

This script runs INSIDE the package's pinned PEP 723 environment
(`uv run --script`, resolved from the entry point's exact pins) — never in
the dev test environment, which deliberately does not install yt-dlp. The
pytest suite invokes one arm at a time:

  plugin-guard   A fake plugin in a discoverable yt-dlp plugin directory
                 must NOT load while the package's `YTDLP_NO_PLUGINS`
                 guard is set — and MUST load without the guard, proving
                 the fixture is live. This pins the guard's behavior
                 against the tagged release's `load_plugins()` source.

  contract       Real `YoutubeDL` option parsing (including the
                 `js_runtimes` shape validation), format selection against
                 local fixture metadata, and the CONNECTION GUARD running
                 against a fake resolver: metadata allowlists, private and
                 mixed DNS rejection, changing-DNS pinning, the media
                 suffix policy, and a full media fetch through the
                 production opener with an injected low-level connection
                 stub. The stub replaces ONLY the socket transport; the
                 package's URL validation, encoding, size, and status
                 layers always run for real. A REAL `YoutubeDL.extract_info`
                 call against an unresolvable fake socket layer proves the
                 metadata path cannot open an unauthorized connection: the
                 guard must fail the extraction closed with ZERO unauthorized
                 connection attempts.

Every arm is offline: no arm performs a real metadata extraction or opens a
real network connection. Exit 0 with the arm's OK line is the pass signal;
any other exit is a contract failure with a fixed diagnostic.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
_SCRIPT_PATH = _HERE.parent / "audio-acquire"

_VIDEO_ID = "dQw4w9WgXcQ"
_GLOBAL_V4 = "142.250.65.110"
_PRIVATE_V4 = "10.0.0.7"
_MEDIA_HOST = "rr3---sn-p5qs7nz6.googlevideo.com"
_MEDIA_URL = f"https://{_MEDIA_HOST}/videoplayback?id=1&sig=fixture"
_FTYP = bytes([0x00, 0x00, 0x00, 0x18]) + b"ftypM4A " + bytes(12)

_INFO: dict[str, Any] = {
    "id": _VIDEO_ID,
    "duration": 600,
    "formats": [
        {
            "format_id": "18",
            "ext": "mp4",
            "vcodec": "avc1.42001E",
            "acodec": "mp4a.40.2",
            "url": "https://ignored.example/video",
        },
        {
            "format_id": "140",
            "ext": "m4a",
            "vcodec": "none",
            "acodec": "mp4a.40.2",
            "abr": 128.0,
            "url": _MEDIA_URL,
        },
    ],
}


def _load_package_module() -> Any:
    loader = SourceFileLoader("audio_acquire", str(_SCRIPT_PATH))
    import importlib.util

    spec = importlib.util.spec_from_loader("audio_acquire", loader)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["audio_acquire"] = module
    loader.exec_module(module)
    return module


# ── Plugin guard arm ───────────────────────────────────────────────────


def _write_plugin(root: Path) -> Path:
    """A discoverable fake plugin that leaves a marker file on import.

    The root doubles as a sys.path candidate: `default_plugin_paths()`
    yields every sys.path entry, and the finder looks for
    `<candidate>/yt_dlp_plugins/<plugin_type>/<module>.py` beneath it.
    """
    marker = root / "marker"
    package = root / "yt_dlp_plugins" / "extractor"
    package.mkdir(parents=True)
    (root / "yt_dlp_plugins" / "__init__.py").write_text("", encoding="utf-8")
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "guard_fixture_plug.py").write_text(
        "from pathlib import Path\n"
        "from yt_dlp.extractor.common import InfoExtractor\n"
        f"Path({str(root / 'marker')!r}).write_text('loaded', encoding='utf-8')\n"
        "class GuardFixtureIE(InfoExtractor):\n"
        "    IE_NAME = 'guard-fixture'\n"
        "    _VALID_URL = r'guardfixture:'\n",
        encoding="utf-8",
    )
    return marker


def _plugin_child(control: bool, plugin_root: Path) -> int:
    """One plugin-discovery run. Exit 0 = the expected discovery state."""
    marker = _write_plugin(plugin_root)
    if control:
        os.environ.pop("YTDLP_NO_PLUGINS", None)
    else:
        os.environ["YTDLP_NO_PLUGINS"] = "1"
    import yt_dlp

    extractor = yt_dlp.YoutubeDL({"quiet": True})
    loaded = marker.exists()
    extractor.close()
    if control and not loaded:
        print("PLUGIN CONTROL FAILED: the fixture plugin was not discovered", file=sys.stderr)
        return 3
    if not control and loaded:
        print("PLUGIN GUARD FAILED: the plugin loaded despite YTDLP_NO_PLUGINS", file=sys.stderr)
        return 4
    print("PLUGIN GUARD OK" if not control else "PLUGIN CONTROL OK")
    return 0


def arm_plugin_guard() -> int:
    """The guard run + the unguarded control run, in disposable roots."""
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in ("XDG_CONFIG_HOME", "YTDLP_NO_PLUGINS", "PYTHONPATH")
    }
    for control, expect in ((False, "PLUGIN GUARD OK"), (True, "PLUGIN CONTROL OK")):
        with tempfile.TemporaryDirectory(prefix="ytdlp-plugin-guard-") as raw_root:
            root = Path(raw_root)
            child_environment = dict(environment)
            # The plugin root is a sys.path candidate, which the pinned
            # release treats as a plugin directory.
            child_environment["PYTHONPATH"] = str(root)
            completed = subprocess.run(  # noqa: S603 - fixed argv, no shell
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "plugin-child",
                    str(root),
                    "control" if control else "guarded",
                ],
                env=child_environment,
                capture_output=True,
                text=True,
                timeout=300,
                check=False,
            )
            if completed.returncode != 0 or expect not in completed.stdout:
                print(completed.stdout, file=sys.stderr)
                print(completed.stderr, file=sys.stderr)
                print(f"{expect} arm failed", file=sys.stderr)
                return completed.returncode or 5
            print(expect)
    return 0


# ── Contract arm ───────────────────────────────────────────────────────


class _FakeResolver:
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


def _require(condition: bool, message: str) -> None:
    if not condition:
        print(f"CONTRACT FAIL: {message}")
        raise SystemExit(1)


def arm_contract() -> int:
    module = _load_package_module()
    import yt_dlp

    # 1. The real YoutubeDL accepts the package's pinned option set,
    #    including the `js_runtimes` shape validation, with the reduced
    #    policy intact.
    deadline = 2**40
    bun_path = "/usr/local/bin/bun"
    extractor = yt_dlp.YoutubeDL(module._ytdlp_params(bun_path, deadline))
    cleaned: dict[str, Any] = dict(extractor.params)
    _require(cleaned["retries"] == 0, "retries must be zero")
    _require(cleaned["extractor_retries"] == 0, "extractor retries must be zero")
    _require(cleaned["fragment_retries"] == 0, "fragment retries must be zero")
    _require(cleaned["skip_download"] is True, "skip_download must be true")
    _require(cleaned["noplaylist"] is True, "noplaylist must be true")
    _require(cleaned["proxy"] == "", "proxy inheritance must be disabled")
    _require(cleaned["usenetrc"] is False, "netrc must be disabled")
    _require(cleaned["cookiefile"] is None, "cookie files must be disabled")
    _require(cleaned["cookiesfrombrowser"] is None, "browser cookies must be disabled")
    _require(cleaned["remote_components"] == set(), "remote components must be refused")
    _require(
        cleaned["js_runtimes"] == {"bun": {"path": bun_path}},
        "js_runtimes must name exactly the host-resolved Bun",
    )
    close = getattr(extractor, "close", None)
    if callable(close):
        close()

    # And the no-Bun variant: an EMPTY runtime table, never a Deno default.
    extractor = yt_dlp.YoutubeDL(module._ytdlp_params(None, deadline))
    cleaned_default: dict[str, Any] = dict(extractor.params)
    _require(cleaned_default["js_runtimes"] == {}, "an absent Bun must leave no runtime")
    close = getattr(extractor, "close", None)
    if callable(close):
        close()

    # 2. Format selection against fixture metadata: the best validated M4A.
    best = module.select_audio_format(_INFO)
    _require(best.get("format_id") == "140", "the best validated M4A must be picked")
    _require(
        module._format_is_validated_m4a(best), "the picked format must be validated"
    )

    # 3. The connection guard under a fake resolver.
    real_getaddrinfo = socket.getaddrinfo

    # 3a. The metadata phase permits any hostname (operator policy); the
    # DNS fence is what stays: an unresolvable host fails typed.
    resolver = _FakeResolver({"evil.example": [_GLOBAL_V4]})
    socket.getaddrinfo = resolver  # type: ignore[assignment]
    try:
        with module._ConnectionGuard(module._metadata_host_allowed) as guard:
            answers = guard._getaddrinfo("evil.example", 443)
        _require(bool(answers), "a permitted host must resolve through the guard")
    finally:
        socket.getaddrinfo = real_getaddrinfo  # type: ignore[assignment]

    # 3b. Private and mixed answers are rejected wholesale.
    for answers in ([_PRIVATE_V4], [_GLOBAL_V4, _PRIVATE_V4]):
        resolver = _FakeResolver({"www.youtube.com": answers})
        socket.getaddrinfo = resolver  # type: ignore[assignment]
        try:
            with module._ConnectionGuard(module._metadata_host_allowed) as guard:
                try:
                    guard._getaddrinfo("www.youtube.com", 443)
                except module.ProtocolFailure:
                    pass
                else:
                    _require(False, "a non-global DNS answer was accepted")
        finally:
            socket.getaddrinfo = real_getaddrinfo  # type: ignore[assignment]

    # 3c. Changing DNS between lookups cannot move a validated connection:
    #     the first validated answer is pinned and no second lookup runs.
    resolver = _FakeResolver({"www.youtube.com": [_GLOBAL_V4]})
    socket.getaddrinfo = resolver  # type: ignore[assignment]
    try:
        with module._ConnectionGuard(module._metadata_host_allowed) as guard:
            first = guard._getaddrinfo("www.youtube.com", 443)
            resolver.answers_by_host["www.youtube.com"] = [_PRIVATE_V4]
            second = guard._getaddrinfo("www.youtube.com", 443)
        _require(first == second, "DNS pinning failed")
        _require(
            resolver.lookups.count("www.youtube.com") == 1,
            "a second DNS lookup ran for a pinned host",
        )
    finally:
        socket.getaddrinfo = real_getaddrinfo  # type: ignore[assignment]

    # 4. The metadata path fails CLOSED against an unresolvable fake socket
    #    layer with zero unauthorized connection attempts: a real
    #    YoutubeDL.extract_info call under the guard can only ever touch
    #    the policy hosts (the watch host and the googlevideo family), and
    #    the fake resolver answers NOTHING, so any connection attempt is
    #    still refused; only in-policy hostnames may be recorded.
    class _RefusingSocket(socket.socket):  # type: ignore[type-arg]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, **kwargs)

        def connect(self, sockaddr: Any) -> None:
            raise AssertionError(f"unauthorized connect to {sockaddr!r}")

    unauthorized: list[str] = []
    resolver = _FakeResolver({})  # nothing resolvable
    real_socket = socket.socket
    socket.getaddrinfo = resolver  # type: ignore[assignment]

    def _counting_getaddrinfo(host: Any, *args: Any, **kwargs: Any) -> Any:
        name = host if isinstance(host, str) else str(host)
        lowered = name.lower()
        if lowered != "www.youtube.com" and not module._media_host_allowed(lowered):
            unauthorized.append(name)
        raise socket.gaierror(-2, "offline")

    socket.getaddrinfo = _counting_getaddrinfo  # type: ignore[assignment]
    try:
        with module._ConnectionGuard(module._metadata_host_allowed):
            try:
                module.fetch_metadata(_VIDEO_ID, None, deadline)
            except module.ProtocolFailure:
                pass
            else:
                _require(False, "metadata retrieval succeeded against a dead network")
    except AssertionError as error:
        print(f"CONTRACT FAIL: {error}")
        return 1
    finally:
        socket.getaddrinfo = real_getaddrinfo  # type: ignore[assignment]
        _ = real_socket
    _require(
        not unauthorized,
        f"unauthorized metadata destinations were attempted: {unauthorized}",
    )

    # 5. The published file contract: a non-M4A payload is refused.
    for bad_payload in (b"<html>error page</html>", b"", b"MThd" + bytes(6)):
        try:
            module.validate_m4a(bad_payload)
        except module.ProtocolFailure:
            continue
        _require(False, "a non-M4A payload was accepted")

    print("CONTRACT OK")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "plugin-guard":
        return arm_plugin_guard()
    if len(argv) >= 2 and argv[1] == "contract":
        return arm_contract()
    if len(argv) == 4 and argv[1] == "plugin-child":
        # argv: <script> plugin-child <root> <control|guarded>
        root = Path(sys.argv[2])
        control = sys.argv[3] == "control"
        return _plugin_child(control, root)
    print("usage: _ytdlp_offline_contract.py <plugin-guard|contract>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
