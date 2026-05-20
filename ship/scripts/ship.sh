#!/usr/bin/env bash
set -euo pipefail

BASE_REF="origin/main"
BASE_BRANCH="main"
REMOTE="origin"
COMMIT_MESSAGE=""
PR_TITLE=""
PR_BODY_FILE=""

usage() {
  cat <<'USAGE'
Usage: ship.sh [options]

Options:
  --base-ref REF            Rebase against this ref. Default: origin/main
  --base-branch BRANCH      PR base branch. Default: main
  --remote REMOTE           Git remote to fetch/push. Default: origin
  --commit-message TEXT     Commit message for local changes.
  --pr-title TEXT           Pull request title.
  --pr-body-file PATH       Markdown file to use as the PR body.
  -h, --help                Show this help.

Environment overrides:
  SHIP_FORMAT_CMD           Format command run with bash -lc.
  SHIP_LINT_CMD             Lint/check command run with bash -lc.
  SHIP_TEST_CMD             Test command run with bash -lc.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-ref)
      BASE_REF="${2:?missing value for --base-ref}"
      shift 2
      ;;
    --base-branch)
      BASE_BRANCH="${2:?missing value for --base-branch}"
      shift 2
      ;;
    --remote)
      REMOTE="${2:?missing value for --remote}"
      shift 2
      ;;
    --commit-message)
      COMMIT_MESSAGE="${2:?missing value for --commit-message}"
      shift 2
      ;;
    --pr-title)
      PR_TITLE="${2:?missing value for --pr-title}"
      shift 2
      ;;
    --pr-body-file)
      PR_BODY_FILE="${2:?missing value for --pr-body-file}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  printf '\n==> %s\n' "$*"
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

run_shell() {
  local command="$1"
  printf '+ bash -lc %q\n' "$command"
  bash -lc "$command"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

has_changes() {
  [[ -n "$(git status --porcelain)" ]]
}

package_manager() {
  if [[ -f pnpm-lock.yaml ]] && command_exists pnpm; then
    echo pnpm
  elif [[ -f package-lock.json ]] && command_exists npm; then
    echo npm
  elif [[ -f yarn.lock ]] && command_exists yarn; then
    echo yarn
  elif [[ -f package.json ]] && command_exists pnpm; then
    echo pnpm
  elif [[ -f package.json ]] && command_exists npm; then
    echo npm
  elif [[ -f package.json ]] && command_exists yarn; then
    echo yarn
  fi
}

has_package_script() {
  local script="$1"
  [[ -f package.json ]] || return 1
  command_exists node || return 1
  node -e 'const fs=require("fs"); const script=process.argv[1]; const pkg=JSON.parse(fs.readFileSync("package.json","utf8")); process.exit(pkg.scripts && pkg.scripts[script] ? 0 : 1)' "$script"
}

run_package_script() {
  local pm="$1"
  local script="$2"
  case "$pm" in
    pnpm) run pnpm run "$script" ;;
    npm) run npm run "$script" ;;
    yarn) run yarn "$script" ;;
    *) echo "Unsupported package manager: $pm" >&2; exit 1 ;;
  esac
}

run_format() {
  local ran=0
  local pm
  pm="$(package_manager || true)"

  log "Running format"
  if [[ -n "${SHIP_FORMAT_CMD:-}" ]]; then
    run_shell "$SHIP_FORMAT_CMD"
    return
  fi

  if [[ -n "$pm" ]] && has_package_script format; then
    run_package_script "$pm" format
    ran=1
  elif [[ -n "$pm" ]] && has_package_script fmt; then
    run_package_script "$pm" fmt
    ran=1
  fi

  if [[ -f Cargo.toml ]] && command_exists cargo; then
    run cargo fmt --all
    ran=1
  fi

  if [[ "$ran" -eq 0 ]]; then
    echo "No format command found. Set SHIP_FORMAT_CMD." >&2
    exit 1
  fi
}

run_lint() {
  local ran=0
  local pm
  pm="$(package_manager || true)"

  log "Running lint/check"
  if [[ -n "${SHIP_LINT_CMD:-}" ]]; then
    run_shell "$SHIP_LINT_CMD"
    return
  fi

  if [[ -n "$pm" ]] && has_package_script lint; then
    run_package_script "$pm" lint
    ran=1
  elif [[ -n "$pm" ]] && has_package_script check; then
    run_package_script "$pm" check
    ran=1
  fi

  if [[ -f Cargo.toml ]] && command_exists cargo; then
    run cargo clippy --workspace --all-targets -- -D warnings
    ran=1
  fi

  if [[ "$ran" -eq 0 ]]; then
    echo "No lint/check command found. Set SHIP_LINT_CMD." >&2
    exit 1
  fi
}

run_tests() {
  local ran=0
  local pm
  pm="$(package_manager || true)"

  log "Running tests"
  if [[ -n "${SHIP_TEST_CMD:-}" ]]; then
    run_shell "$SHIP_TEST_CMD"
    return
  fi

  if [[ -n "$pm" ]] && has_package_script test; then
    run_package_script "$pm" test
    ran=1
  fi

  if [[ -f Cargo.toml ]] && command_exists cargo; then
    run cargo test --workspace
    ran=1
  fi

  if [[ "$ran" -eq 0 ]]; then
    echo "No test command found. Set SHIP_TEST_CMD." >&2
    exit 1
  fi
}

make_default_body() {
  local path="$1"
  {
    echo "## Summary"
    echo "- Prepares branch \`$(git branch --show-current)\` for review."
    echo
    echo "## Changes"
    git log --oneline "$BASE_REF..HEAD" | sed 's/^/- /'
    echo
    echo "## Validation"
    if [[ -n "${SHIP_FORMAT_CMD:-}" ]]; then
      echo "- \`$SHIP_FORMAT_CMD\`"
    else
      echo "- repository format command(s)"
    fi
    if [[ -n "${SHIP_LINT_CMD:-}" ]]; then
      echo "- \`$SHIP_LINT_CMD\`"
    else
      echo "- repository lint/check command(s)"
    fi
    if [[ -n "${SHIP_TEST_CMD:-}" ]]; then
      echo "- \`$SHIP_TEST_CMD\`"
    else
      echo "- repository test command(s)"
    fi
  } > "$path"
}

if ! command_exists git; then
  echo "git is required." >&2
  exit 1
fi

if ! command_exists gh; then
  echo "GitHub CLI 'gh' is required." >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BRANCH="$(git branch --show-current)"
if [[ -z "$BRANCH" ]]; then
  echo "Refusing to ship from detached HEAD." >&2
  exit 1
fi

if [[ "$BRANCH" == "$BASE_BRANCH" || "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
  echo "Refusing to ship protected branch '$BRANCH'." >&2
  exit 1
fi

log "Fetching $REMOTE/$BASE_BRANCH"
run git fetch "$REMOTE" "$BASE_BRANCH"

STASHED=0
if has_changes; then
  log "Stashing local work before rebase"
  run git stash push -u -m "ship-autostash-$BRANCH"
  STASHED=1
fi

log "Rebasing $BRANCH onto $BASE_REF"
run git rebase "$BASE_REF"

if [[ "$STASHED" -eq 1 ]]; then
  log "Restoring stashed work"
  run git stash pop
fi

run_format
run_lint
run_tests

log "Checking whitespace errors"
run git diff --check

if has_changes; then
  log "Committing changes"
  run git add -A
  if [[ -z "$COMMIT_MESSAGE" ]]; then
    COMMIT_MESSAGE="Ship changes"
  fi
  run git commit -m "$COMMIT_MESSAGE"
else
  log "No local changes to commit"
fi

if has_changes; then
  echo "Working tree is still dirty after commit." >&2
  git status --short >&2
  exit 1
fi

log "Pushing $BRANCH"
run git push -u "$REMOTE" "$BRANCH"

if [[ -z "$PR_TITLE" ]]; then
  PR_TITLE="$(git log -1 --pretty=%s)"
fi

TEMP_BODY=""
if [[ -z "$PR_BODY_FILE" ]]; then
  TEMP_BODY="$(mktemp)"
  PR_BODY_FILE="$TEMP_BODY"
  make_default_body "$PR_BODY_FILE"
fi

if [[ ! -f "$PR_BODY_FILE" ]]; then
  echo "PR body file does not exist: $PR_BODY_FILE" >&2
  exit 1
fi

log "Creating or updating pull request"
if PR_URL="$(gh pr view --json url --jq .url 2>/dev/null)"; then
  run gh pr edit --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
  echo "$PR_URL"
else
  gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
fi

if [[ -n "$TEMP_BODY" ]]; then
  rm -f "$TEMP_BODY"
fi
