# AGENTS.md — pdf2md

Python tool for PDF-to-Markdown conversion using docling + granite-docling.

## Before committing changes

```bash
uv run ruff format pdf2md tests/
uv run ruff check pdf2md tests/
uv run pyright pdf2md tests/
uv run pytest tests/ -v
```

All four must pass with zero errors.

## Rules

- Keep `pdf2md` runnable as `./pdf2md` (shebang + PEP 723 inline metadata).
- Keep the PEP 723 `# /// script` deps in sync with `pyproject.toml` dependencies.
- Public API (`convert_pdf`) is decorated with `@beartype` — keep it that way.
- Docstring at the top of `pdf2md` is the user-facing documentation.
- Tests import the module via `SourceFileLoader("pdf2md", ...).load_module()`.
