---
name: ship
description: Non-interactive release-readiness workflow for Git branches. Use when Codex is asked to ship, prepare a PR, publish a branch, or finish work by rebasing on origin/main, formatting, linting/checking, running all tests, committing local changes, pushing to GitHub, and creating or updating a pull request with a structured description.
---

# ship

## Overview

Use this skill to take a working branch from local changes to a ready GitHub PR without interactive prompts.

The bundled script handles the fragile command sequence. Codex should still inspect the diff first so it can provide meaningful commit and PR text.

## Workflow

1. Inspect the repository state:

   ```bash
   git status --short
   git diff --stat origin/main...
   git diff origin/main...
   ```

2. Draft:

   - a concise imperative commit message
   - a PR title
   - a structured PR body with `## Summary`, `## Changes`, and `## Validation`

3. Save the PR body in a temporary file under `.context/` when that directory exists, otherwise use a temp file.

4. Run the shipping script non-interactively:

   ```bash
   /Users/kaustubh/.codex/skills/ship/scripts/ship.sh \
     --commit-message "Add concise message here" \
     --pr-title "Add concise PR title here" \
     --pr-body-file .context/ship-pr-body.md
   ```

5. Report the PR URL and the validation commands that passed.

## Script Behavior

`scripts/ship.sh` performs this sequence:

1. Verify the current directory is a Git repository on a non-main branch.
2. Verify `git` and `gh` are available.
3. Fetch `origin/main`.
4. Stash dirty and untracked work, rebase the current branch against `origin/main`, then restore the stash.
5. Run format commands, lint/check commands, and test commands.
6. Commit all resulting changes if any exist.
7. Push the branch to `origin`.
8. Create a PR against `main`, or update the existing branch PR body/title when one already exists.

If a rebase conflict, formatter/linter/test failure, missing command category, failed push, or GitHub CLI error occurs, the script exits non-zero and leaves the repository in the state needed for Codex to inspect and fix the issue. Do not continue to later shipping steps manually until the failing step is clean.

## Command Detection

The script auto-detects common project commands:

- Format: `pnpm|npm|yarn run format`, `pnpm|npm|yarn run fmt`, and/or `cargo fmt --all`
- Lint/check: `pnpm|npm|yarn run lint`, `pnpm|npm|yarn run check`, and/or `cargo clippy --workspace --all-targets -- -D warnings`
- Tests: `pnpm|npm|yarn run test` and/or `cargo test --workspace`

Override any phase with environment variables when a repository needs different commands:

```bash
SHIP_FORMAT_CMD="pnpm format" \
SHIP_LINT_CMD="pnpm lint" \
SHIP_TEST_CMD="pnpm test" \
/Users/kaustubh/.codex/skills/ship/scripts/ship.sh ...
```

Each override is executed with `bash -lc`. The workflow remains non-interactive.

## PR Body Expectations

Use a structured body like:

```markdown
## Summary
- One or two bullets describing the user-visible result.

## Changes
- Main implementation changes.
- Tests or docs added.

## Validation
- `cargo fmt --all`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
```

Keep the description factual. Include environment variables or skipped validations only when relevant.
