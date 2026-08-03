#!/usr/bin/env python3
# pattern: Imperative Shell

"""Validate the metadata in every repository skill."""

# /// script
# dependencies = ["pyyaml"]
# ///

import re
import sys
from pathlib import Path

import yaml


MAX_SKILL_NAME_LENGTH = 64
ALLOWED_FRONTMATTER_KEYS = {
    "name",
    "description",
    "license",
    "allowed-tools",
    "metadata",
}


def validate_skill(skill_path: Path) -> str | None:
    skill_file = skill_path / "SKILL.md"
    if not skill_file.exists():
        return "SKILL.md not found"

    content = skill_file.read_text()
    if not content.startswith("---"):
        return "no YAML frontmatter found"

    match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not match:
        return "invalid frontmatter format"

    try:
        frontmatter = yaml.safe_load(match.group(1))
    except yaml.YAMLError as error:
        return f"invalid YAML in frontmatter: {error}"

    if not isinstance(frontmatter, dict):
        return "frontmatter must be a YAML dictionary"

    unexpected_keys = set(frontmatter) - ALLOWED_FRONTMATTER_KEYS
    if unexpected_keys:
        return f"unexpected frontmatter keys: {', '.join(sorted(unexpected_keys))}"

    name = frontmatter.get("name")
    if not isinstance(name, str) or not name.strip():
        return "missing or invalid 'name'"
    name = name.strip()
    if not re.fullmatch(r"[a-z0-9-]+", name):
        return "name must use lowercase letters, digits, and hyphens"
    if name.startswith("-") or name.endswith("-") or "--" in name:
        return "name cannot start or end with a hyphen or contain consecutive hyphens"
    if len(name) > MAX_SKILL_NAME_LENGTH:
        return f"name exceeds {MAX_SKILL_NAME_LENGTH} characters"

    description = frontmatter.get("description")
    if not isinstance(description, str) or not description.strip():
        return "missing or invalid 'description'"
    if "<" in description or ">" in description:
        return "description cannot contain angle brackets"
    if len(description.strip()) > 1024:
        return "description exceeds 1024 characters"

    return None


def main() -> int:
    skill_files = sorted(Path("docs/skills").glob("*/SKILL.md"))
    if not skill_files:
        print("No skills found", file=sys.stderr)
        return 1

    failures = 0
    for skill_file in skill_files:
        error = validate_skill(skill_file.parent)
        if error:
            print(f"{skill_file}: {error}", file=sys.stderr)
            failures += 1
        else:
            print(f"{skill_file}: valid")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
