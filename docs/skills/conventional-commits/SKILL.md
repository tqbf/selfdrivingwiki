---
name: conventional-commits
description: Use when creating, reviewing, or correcting Git commit messages - applies the Conventional Commits 1.0.0 format and helps select an accurate type, scope, and breaking-change marker
---

# Conventional Commits

Use this skill for commits and commit-message reviews. A structured commit message makes the change clear to people and tools such as changelog generators and release automation.

## Format

Write the header in this form:

```text
<type>[optional scope][!]: <description>
```

Add an optional body after one blank line. Add one or more optional footers after another blank line.

```text
feat(search): add source title matching

Include source titles in the lexical search index.

Closes: #123
```

Use a noun for the type and describe the affected area in the scope. Use lowercase types and scopes. Write a short, imperative description that states the user-visible or repository-level change.

## Type selection

Choose the type that best describes the change:

- `feat`: add a feature. This maps to a SemVer minor release.
- `fix`: correct a bug. This maps to a SemVer patch release.
- `refactor`: change structure without changing behavior.
- `perf`: improve performance without changing behavior.
- `docs`: change documentation only.
- `test`: add or change tests.
- `build`: change build tools, dependencies, or packaging.
- `ci`: change continuous integration configuration.
- `chore`: make maintenance changes that do not fit another type.

Use the repository's established type when its history or release tooling defines a narrower convention. Do not use `chore` when a more precise type applies.

## Breaking changes

Mark a breaking change with `!` before the colon:

```text
feat(api)!: replace the page identifier format
```

Also add a footer when the reason or migration path needs explanation:

```text
BREAKING CHANGE: clients must send PageID values instead of raw strings.
```

Use the exact uppercase footer token `BREAKING CHANGE:`. A breaking change can use any type.

## Validation

Before committing, inspect the staged diff and write one commit for one coherent change. Check that:

1. The type matches the primary purpose.
2. The scope names a real area of the repository when a scope helps.
3. The description is specific, concise, and does not end with a period.
4. The body explains why when the header does not provide enough context.
5. The footer records issue references or breaking-change details in the format required by the repository.

Use `git diff --cached` to confirm that the message describes the staged change. Follow the repository rule to work on a feature branch and open a pull request. Do not commit directly to `main`.

## Reference

This skill follows [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/).
