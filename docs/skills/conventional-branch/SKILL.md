---
name: conventional-branch
description: 'Create Git branches following the Conventional Branch specification (feature/, bugfix/, hotfix/, release/, chore/). Use when creating a new branch, naming a branch, or checking whether a branch name complies with the spec.'
---

# Conventional Branch

Create Git branches that follow the [Conventional Branch](https://conventional-branch.github.io) specification — a simple, consistent convention for naming Git branches.

## Branch Name Format

```text
<type>/<description>
```

### Branch Types

| Type | Alias | Purpose |
|------|-------|---------|
| `feature/` | `feat/` | New features or enhancements |
| `bugfix/` | `fix/` | Bug fixes |
| `hotfix/` | — | Urgent production fixes |
| `release/` | — | Release preparation (dots allowed in version: `release/v1.2.0`) |
| `chore/` | — | Non-code tasks (deps, docs, config) |

### Trunk Branches

`main`, `master`, and `develop` are trunk branches — they do not use a prefix. Never create new branches with the same names as trunk branches; branch off them instead.

## Naming Rules

- **Lowercase only** — no uppercase letters anywhere
- **Alphanumerics, hyphens, and dots** — `a-z`, `0-9`, `-`, `.`
- **Dots allowed only** in `release/` version descriptions (e.g., `release/v1.2.0`)
- **No underscores, spaces, or special characters**
- **No consecutive hyphens** (`--`), **dots** (`..`), or hyphen-dot adjacency (`-.` or `.-`)
- **No leading or trailing hyphens or dots** in the description

## Valid Examples

```text
main
master
develop
feature/add-login-page
feat/add-login-page
bugfix/fix-header-bug
fix/header-bug
hotfix/security-patch
release/v1.2.0
chore/update-dependencies
feature/issue-123-new-login
```

## Invalid Examples

| Branch | Problem |
|--------|---------|
| `Feature/Add-Login` | Uppercase letters |
| `feature/new--login` | Consecutive hyphens |
| `feature/-new-login` | Leading hyphen |
| `feature/new-login-` | Trailing hyphen |
| `release/v1.-2.0` | Hyphen adjacent to dot |
| `fix/header bug` | Space |
| `fix/header_bug` | Underscore |
| `unknown/some-task` | Unknown prefix type |

## Description Guidelines

- Use kebab-case with 2-5 words
- Be descriptive but concise (~50 chars total)
- Good: `add-oauth-login`, `fix-header-overflow`, `update-ci-config`
- Bad: `fix-bug`, `new-feature`

## Workflow

1. Determine the branch type; default to `feature` when uncertain.
2. Write a brief description of the work. Include a ticket or issue number when one exists.
3. Validate the assembled name against the naming rules. Lowercase it, replace underscores and spaces with hyphens, collapse consecutive hyphens, and strip leading/trailing hyphens when correcting a draft name.
4. Detect the base branch:

   ```sh
   git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'
   ```

   If that returns nothing, check local `develop`, `main`, then `master`.
5. Create the branch from the base branch and confirm the resulting name:

   ```sh
   git checkout <base>
   git pull origin <base>
   git checkout -b <type>/<description>
   ```

6. Remind the user to run `git push -u origin <branch-name>` when ready.

## Relationship with Conventional Commits

Conventional Branch complements [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Align the branch type with commit types where possible: `feature/*` with `feat:`, `bugfix/*` with `fix:`, and `chore/*` with `chore:`.
