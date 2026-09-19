"""Unit tests for the pure policy helpers of the zotero package.

Covers the request-URL grammar, the MIME → output-route mapping table (the
port of the retired Swift `ZoteroAttachment.isIngestable` policy), creator
summarization, article-metadata mapping, and credential-file reading. No
network: every helper is a pure function.
"""

from __future__ import annotations

import json
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "zotero"
assert _SCRIPT_PATH.exists(), f"zotero script not found at {_SCRIPT_PATH}"

_loader = SourceFileLoader("zotero", str(_SCRIPT_PATH))
_zotero = _loader.load_module()


# ── Request URL grammar ────────────────────────────────────────────────────


class TestParseAttachmentFileURL:
    def test_accepts_canonical_url(self) -> None:
        parsed = _zotero.parse_attachment_file_url(
            "https://api.zotero.org/users/12345/items/ABCD1234/file"
        )
        assert parsed == ("12345", "ABCD1234")

    def test_accepts_default_https_port_explicitly(self) -> None:
        parsed = _zotero.parse_attachment_file_url(
            "https://api.zotero.org:443/users/1/items/ABCD1234/file"
        )
        assert parsed == ("1", "ABCD1234")

    def test_rejects_http_scheme(self) -> None:
        assert (
            _zotero.parse_attachment_file_url(
                "http://api.zotero.org/users/1/items/ABCD1234/file"
            )
            is None
        )

    def test_rejects_wrong_host(self) -> None:
        assert (
            _zotero.parse_attachment_file_url(
                "https://evil.example.com/users/1/items/ABCD1234/file"
            )
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org.evil.example/users/1/items/ABCD1234/file"
            )
            is None
        )

    def test_rejects_query_and_fragment(self) -> None:
        base = "https://api.zotero.org/users/1/items/ABCD1234/file"
        assert _zotero.parse_attachment_file_url(f"{base}?x=1") is None
        assert _zotero.parse_attachment_file_url(f"{base}#frag") is None

    def test_rejects_userinfo_and_nondefault_port(self) -> None:
        assert (
            _zotero.parse_attachment_file_url(
                "https://user:pass@api.zotero.org/users/1/items/ABCD1234/file"
            )
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org:8443/users/1/items/ABCD1234/file"
            )
            is None
        )

    def test_rejects_wrong_path_shapes(self) -> None:
        assert (
            _zotero.parse_attachment_file_url("https://api.zotero.org/users/1/items/ABCD1234")
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/groups/1/items/ABCD1234/file"
            )
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/users/1/items/ABCD1234/children"
            )
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/users/1/items/ABCD1234/file/extra"
            )
            is None
        )
        assert _zotero.parse_attachment_file_url("https://api.zotero.org/") is None

    def test_rejects_malformed_ids(self) -> None:
        # Non-numeric library ID.
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/users/abc/items/ABCD1234/file"
            )
            is None
        )
        # Lowercase / 7-char / 9-char attachment keys.
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/users/1/items/abcd1234/file"
            )
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/users/1/items/ABCD123/file"
            )
            is None
        )
        assert (
            _zotero.parse_attachment_file_url(
                "https://api.zotero.org/users/1/items/ABCD12345/file"
            )
            is None
        )

    def test_rejects_non_url_input(self) -> None:
        assert _zotero.parse_attachment_file_url("not a url") is None
        assert _zotero.parse_attachment_file_url("") is None


# ── Output-route mapping (each reviewed row) ───────────────────────────────


class TestResolveOutput:
    def test_markdown_content_types(self) -> None:
        assert _zotero.resolve_output("text/markdown", "x.md") == ("markdown", None)
        assert _zotero.resolve_output("text/plain", "x.txt") == ("markdown", None)

    def test_pdf_content_type(self) -> None:
        assert _zotero.resolve_output("application/pdf", "x.pdf") == (
            "bytes",
            "application/pdf",
        )

    def test_html_content_type(self) -> None:
        assert _zotero.resolve_output("text/html", "x.html") == ("bytes", "text/html")

    def test_filename_fallback_rows(self) -> None:
        assert _zotero.resolve_output(None, "notes.md") == ("markdown", None)
        assert _zotero.resolve_output("", "paper.pdf") == ("bytes", "application/pdf")
        assert _zotero.resolve_output(None, "page.html") == ("bytes", "text/html")
        assert _zotero.resolve_output(None, "page.htm") == ("bytes", "text/html")

    def test_content_type_wins_over_filename(self) -> None:
        assert _zotero.resolve_output("text/html", "misleading.pdf") == ("bytes", "text/html")
        assert _zotero.resolve_output("application/pdf", "misleading.md") == (
            "bytes",
            "application/pdf",
        )

    def test_unmatched_content_type_falls_back_to_filename(self) -> None:
        # The Swift policy fell through to the filename heuristic when the
        # API content type was present but unmatched.
        assert _zotero.resolve_output("application/octet-stream", "p.pdf") == (
            "bytes",
            "application/pdf",
        )

    def test_unsupported_rows(self) -> None:
        assert _zotero.resolve_output("image/png", "pic.png") is None
        assert _zotero.resolve_output("application/zip", "a.zip") is None
        assert _zotero.resolve_output(None, "a.docx") is None
        assert _zotero.resolve_output(None, None) is None
        assert _zotero.resolve_output("", "") is None

    def test_matching_is_case_insensitive(self) -> None:
        assert _zotero.resolve_output("APPLICATION/PDF", "x") == ("bytes", "application/pdf")
        assert _zotero.resolve_output("Text/Markdown", "x") == ("markdown", None)


# ── Creators and article metadata ──────────────────────────────────────────


class TestSummarizeCreators:
    def test_two_person_creators(self) -> None:
        creators: list[dict[str, Any]] = [
            {"creatorType": "author", "firstName": "Jane", "lastName": "Doe"},
            {"creatorType": "author", "firstName": "Ann", "lastName": "Roe"},
        ]
        assert _zotero.summarize_creators(creators) == "Doe, J.; Roe, A."

    def test_single_field_name_passes_through(self) -> None:
        creators = [{"creatorType": "author", "name": "ACME Research"}]
        assert _zotero.summarize_creators(creators) == "ACME Research"

    def test_last_name_without_first_name(self) -> None:
        creators = [{"creatorType": "author", "lastName": "Cher"}]
        assert _zotero.summarize_creators(creators) == "Cher"

    def test_empty_and_invalid_inputs(self) -> None:
        assert _zotero.summarize_creators([]) is None
        assert _zotero.summarize_creators(None) is None
        assert _zotero.summarize_creators("nope") is None
        assert _zotero.summarize_creators([{"firstName": "", "lastName": ""}]) is None


class TestArticleMetadataFrom:
    def _parent(self, **data: Any) -> dict[str, Any]:
        return {"key": "PARENT01", "version": 1, "data": {"key": "PARENT01", **data}}

    def test_full_parent_mapping(self) -> None:
        attachment = {"key": "ATTACH01", "title": "PDF", "filename": "a.pdf"}
        parent = self._parent(
            itemType="journalArticle",
            title="A Study",
            date="2024-05-01",
            creators=[{"creatorType": "author", "firstName": "Jane", "lastName": "Doe"}],
        )
        assert _zotero.article_metadata_from(parent, attachment) == {
            "title": "A Study",
            "author": "Doe, J.",
            "published": "2024-05-01",
            "identifier": "PARENT01",
        }

    def test_missing_parent_falls_back_to_attachment(self) -> None:
        attachment = {"key": "ATTACH01", "title": "Standalone note"}
        assert _zotero.article_metadata_from(None, attachment) == {
            "title": "Standalone note",
            "identifier": "ATTACH01",
        }

    def test_failed_parent_still_yields_identifier(self) -> None:
        # A parent fetch that returned a non-envelope degrades to the
        # attachment's own parentItem; with none present, the identifier
        # falls back to the attachment key.
        attachment = {"key": "ATTACH01", "title": "T", "parentItem": "PARENT01"}
        metadata = _zotero.article_metadata_from({"data": None}, attachment)
        assert metadata is not None
        assert metadata["identifier"] == "PARENT01"

    def test_overlong_title_is_truncated_not_rejected(self) -> None:
        attachment = {"key": "ATTACH01", "title": "x" * 5_000}
        metadata = _zotero.article_metadata_from(None, attachment)
        assert metadata is not None
        assert len(metadata["title"].encode("utf-8")) <= 1_024

    def test_multibyte_truncation_stays_utf8_clean(self) -> None:
        attachment = {"key": "ATTACH01", "title": "é" * 2_000}
        metadata = _zotero.article_metadata_from(None, attachment)
        assert metadata is not None
        metadata["title"].encode("utf-8")  # must not raise

    def test_empty_metadata_is_none(self) -> None:
        assert _zotero.article_metadata_from(None, {"key": ""}) is None


# ── Credential file ────────────────────────────────────────────────────────


class TestLoadAPIKey:
    def test_reads_valid_envelope(self, tmp_path: Path) -> None:
        path = tmp_path / "input.json"
        path.write_text(json.dumps({"credentials": {"zotero-api-key": "sekrit"}}))
        assert _zotero.load_api_key(str(path)) == "sekrit"

    def test_missing_path_and_none(self, tmp_path: Path) -> None:
        assert _zotero.load_api_key(None) is None
        assert _zotero.load_api_key(str(tmp_path / "absent.json")) is None

    def test_malformed_and_mistyped_envelopes(self, tmp_path: Path) -> None:
        bad = tmp_path / "bad.json"
        bad.write_text("{not json")
        assert _zotero.load_api_key(str(bad)) is None

        empty = tmp_path / "empty.json"
        empty.write_text(json.dumps([]))
        assert _zotero.load_api_key(str(empty)) is None

        missing = tmp_path / "missing.json"
        missing.write_text(json.dumps({"credentials": {}}))
        assert _zotero.load_api_key(str(missing)) is None

        wrong = tmp_path / "wrong.json"
        wrong.write_text(json.dumps({"credentials": {"zotero-api-key": 42}}))
        assert _zotero.load_api_key(str(wrong)) is None

    def test_blank_value_is_missing(self, tmp_path: Path) -> None:
        path = tmp_path / "blank.json"
        path.write_text(json.dumps({"credentials": {"zotero-api-key": "   "}}))
        assert _zotero.load_api_key(str(path)) is None


class TestOutputLimitConstant:
    def test_mirrors_the_manifest_output_limit(self) -> None:
        # The manifest declares 128 MiB (ExtractorHostLimits output bound);
        # this constant must stay byte-identical. The Swift-side reviewed
        # package test pins the manifest value.
        assert _zotero.MAX_OUTPUT_BYTES == 134_217_728
