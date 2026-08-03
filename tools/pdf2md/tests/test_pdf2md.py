"""Unit tests for pdf2md text-cleanup functions.

Run from the tools/pdf2md directory:
    uv run pytest tests/test_pdf2md.py -v
"""

from __future__ import annotations

import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

# ── Import the pdf2md module (extensionless file) ────────────────────────

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "pdf2md"
assert _SCRIPT_PATH.exists(), f"pdf2md script not found at {_SCRIPT_PATH}"

_pdf2md = SourceFileLoader("pdf2md", str(_SCRIPT_PATH)).load_module()
sys.modules["pdf2md"] = _pdf2md


# ── Regex tests (no spaCy needed) ────────────────────────────────────────


class TestMultiSpacePattern:
    def test_collapses_multiple_spaces_mid_line(self):
        assert _pdf2md._MULTI_SPACE_RE.sub(" ", "hello    world") == "hello world"

    def test_preserves_single_space(self):
        assert _pdf2md._MULTI_SPACE_RE.sub(" ", "hello world") == "hello world"

    def test_preserves_leading_spaces(self):
        assert _pdf2md._MULTI_SPACE_RE.sub(" ", "    indented    code") == "    indented code"

    def test_multiline(self):
        text = "line1    extra\nline2   extra"
        assert _pdf2md._MULTI_SPACE_RE.sub(" ", text) == "line1 extra\nline2 extra"


class TestLineNumberBlockPattern:
    def test_digits_only(self):
        assert _pdf2md._LINE_NUMBER_BLOCK_RE.fullmatch("42")

    def test_digits_and_spaces(self):
        assert _pdf2md._LINE_NUMBER_BLOCK_RE.fullmatch("  42  17  ")

    def test_text_with_digits_not_a_match(self):
        assert not _pdf2md._LINE_NUMBER_BLOCK_RE.fullmatch("42 Introduction")

    def test_empty_not_a_match(self):
        assert not _pdf2md._LINE_NUMBER_BLOCK_RE.fullmatch("")


class TestSoftHyphenPattern:
    def test_removes_soft_hyphen(self):
        assert _pdf2md._SOFT_HYPHEN_RE.sub("", "hy­phen") == "hyphen"

    def test_removes_with_trailing_whitespace(self):
        assert _pdf2md._SOFT_HYPHEN_RE.sub("", "hy­  phen") == "hyphen"

    def test_preserves_normal_hyphen(self):
        assert _pdf2md._SOFT_HYPHEN_RE.sub("", "well-known") == "well-known"


# ── _is_prose tests (no spaCy needed) ────────────────────────────────────


class TestIsProse:
    def test_normal_prose(self):
        assert _pdf2md._is_prose("This is a normal paragraph of text.")

    def test_header_not_prose(self):
        assert not _pdf2md._is_prose("# Heading")
        assert not _pdf2md._is_prose("## Subsection")

    def test_code_fence_not_prose(self):
        assert not _pdf2md._is_prose("```python")

    def test_indented_code_is_prose_after_strip(self):
        """_is_prose strips first; indented code without a fenced-block
        marker looks like prose.  This is correct for PDF output, where
        code only appears inside ``` fences."""
        assert _pdf2md._is_prose("    print('hello')")

    def test_tab_indented_is_prose_after_strip(self):
        assert _pdf2md._is_prose("\tprint('hello')")

    def test_list_items_not_prose(self):
        assert not _pdf2md._is_prose("- item one")
        assert not _pdf2md._is_prose("* item one")

    def test_table_row_not_prose(self):
        assert not _pdf2md._is_prose("| col1 | col2 |")

    def test_blockquote_not_prose(self):
        assert not _pdf2md._is_prose("> quoted text")

    def test_whitespace_only_not_prose(self):
        assert not _pdf2md._is_prose("   ")

    def test_empty_string_not_prose(self):
        assert not _pdf2md._is_prose("")


# ── _should_join tests (needs spaCy — loaded lazily on first call) ───────


@pytest.fixture(scope="module")
def nlp():
    return _pdf2md._get_nlp()


class TestShouldJoin:
    def test_mid_sentence_break(self, nlp):
        b1 = "The results of the experiment showed"
        b2 = "significant improvements in accuracy."
        assert _pdf2md._should_join(b1, b2, nlp)

    def test_period_ends_sentence(self, nlp):
        b1 = "The experiment was successful."
        b2 = "Further analysis confirmed the results."
        assert not _pdf2md._should_join(b1, b2, nlp)

    def test_exclamation_ends_sentence(self, nlp):
        b1 = "What a discovery!"
        b2 = "The implications are far-reaching."
        assert not _pdf2md._should_join(b1, b2, nlp)

    def test_question_ends_sentence(self, nlp):
        b1 = "What does this mean?"
        b2 = "Several interpretations are possible."
        assert not _pdf2md._should_join(b1, b2, nlp)

    def test_empty_blocks_return_false(self, nlp):
        assert not _pdf2md._should_join("", "some text", nlp)
        assert not _pdf2md._should_join("some text", "", nlp)

    def test_whitespace_only_returns_false(self, nlp):
        assert not _pdf2md._should_join("   ", "some text", nlp)


# ── _fix_page_breaks tests ───────────────────────────────────────────────


class TestFixPageBreaks:
    def test_joins_mid_sentence_paragraphs(self):
        text = "The results showed\n\nsignificant improvements."
        result = _pdf2md._fix_page_breaks(text)
        assert result == "The results showed significant improvements."

    def test_keeps_separate_sentences(self):
        text = "The experiment concluded.\n\nFurther work is needed."
        result = _pdf2md._fix_page_breaks(text)
        assert "The experiment concluded." in result
        assert "Further work is needed." in result
        # Must contain the paragraph break
        assert "\n\n" in result

    def test_does_not_join_header_with_prose(self):
        text = "# Results\n\nThe experiment showed improvements."
        result = _pdf2md._fix_page_breaks(text)
        assert "# Results" in result
        assert "The experiment showed improvements." in result
        assert "\n\n" in result

    def test_does_not_join_code_block_with_prose(self):
        text = "```\ncode\n```\n\nExplanation follows."
        result = _pdf2md._fix_page_breaks(text)
        assert "```" in result
        assert "Explanation follows." in result

    def test_preserves_blank_lines_between_headers(self):
        text = "# Section 1\n\n# Section 2"
        result = _pdf2md._fix_page_breaks(text)
        assert result == text


# ── _clean tests ─────────────────────────────────────────────────────────


class TestClean:
    def test_removes_line_number_blocks(self):
        text = "Normal paragraph.\n\n42\n\nAnother paragraph."
        result = _pdf2md._clean(text)
        blocks = result.split("\n\n")
        assert "Normal paragraph." in blocks
        assert "Another paragraph." in blocks
        assert "42" not in blocks

    def test_collapses_multiple_spaces(self):
        text = "This    has    extra    spaces."
        result = _pdf2md._clean(text)
        assert "    " not in result

    def test_removes_soft_hyphens(self):
        text = "hy­phen­ation"
        result = _pdf2md._clean(text)
        assert "­" not in result

    def test_preserves_fenced_code_block_spacing(self):
        text = "```\ncode    here    untouched\n```"
        result = _pdf2md._clean(text)
        assert "```\ncode    here    untouched\n```" in result

    def test_preserves_fenced_code_block_indentation(self):
        text = "```python\ndef foo():\n    pass\n```"
        result = _pdf2md._clean(text)
        assert "    pass" in result

    def test_spaces_outside_fence_still_collapse(self):
        text = "```\ncode\n```\n\nafter    fence"
        result = _pdf2md._clean(text)
        assert "after fence" in result

    def test_empty_text_returns_empty(self):
        assert _pdf2md._clean("") == ""


# ── CLI argument parsing tests (no docling import) ───────────────────────


class TestArgParsing:
    """Tests for build_parser() — no imports beyond stdlib."""

    def test_help_exits_zero(self):
        parser = _pdf2md.build_parser()
        with pytest.raises(SystemExit) as exc:
            parser.parse_args(["--help"])
        assert exc.value.code == 0

    def test_default_pipeline_is_vlm(self):
        parser = _pdf2md.build_parser()
        args = parser.parse_args(["/some/path.pdf"])
        assert args.pipeline == "vlm"

    def test_pipeline_standard(self):
        parser = _pdf2md.build_parser()
        args = parser.parse_args(["--pipeline", "standard", "/some/path.pdf"])
        assert args.pipeline == "standard"

    def test_pipeline_invalid_rejected(self):
        parser = _pdf2md.build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["--pipeline", "invalid", "/some/path.pdf"])

    def test_json_flag(self):
        parser = _pdf2md.build_parser()
        args = parser.parse_args(["--json", "/some/path.pdf"])
        assert args.json is True

    def test_output_short_flag(self):
        parser = _pdf2md.build_parser()
        args = parser.parse_args(["-o", "out.md", "/some/path.pdf"])
        assert str(args.output) == "out.md"

    def test_output_long_flag(self):
        parser = _pdf2md.build_parser()
        args = parser.parse_args(["--output", "out.md", "/some/path.pdf"])
        assert str(args.output) == "out.md"

    def test_input_is_path(self):
        parser = _pdf2md.build_parser()
        args = parser.parse_args(["/some/path.pdf"])
        assert isinstance(args.input, Path)
        assert str(args.input) == "/some/path.pdf"


class TestMainErrorPaths:
    """Test main() error handling — no docling import needed for these paths."""

    def test_nonexistent_file_exits_one(self):
        with pytest.raises(SystemExit) as exc:
            _pdf2md.main(argv=["/nonexistent/path.pdf"])
        assert exc.value.code == 1
