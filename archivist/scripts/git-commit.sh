#!/usr/bin/env bash
# Git Commit - Push scrubbed archive to CodeCommit repository
#
# Commits the contents of a platformer archive into a CodeCommit repository,
# tracking artifact evolution with an independent commit history. Each time
# the scrubbed archive changes (new git SHA or scrub rule update), the diff
# is committed - not mirroring source commits, but recording artifact state.
#
# Usage: bash scripts/git-commit.sh <archive_path> <repo_name> <aws_profile> <aws_region>
#
# Prerequisites: git, aws cli
set -euo pipefail

ARCHIVE_PATH="$(realpath "${1:?Usage: git-commit.sh <archive_path> <repo_name> <aws_profile> <aws_region>}")"
REPO_NAME="${2:?Missing repo_name}"
AWS_PROFILE="${3:?Missing aws_profile}"
AWS_REGION="${4:?Missing aws_region}"

export AWS_PROFILE AWS_REGION

# Validate archive exists
if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "git-commit: archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

# Extract metadata from archive filename (platformer-<date>-<sha>.tar.gz)
ARCHIVE_BASENAME=$(basename "$ARCHIVE_PATH" .tar.gz)

REPO_URL="https://git-codecommit.${AWS_REGION}.amazonaws.com/v1/repos/${REPO_NAME}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Git flags for CodeCommit credential helper - passed inline, no global config changes
GIT_CC=(
  -c "credential.helper=!aws codecommit credential-helper \$@"
  -c "credential.UseHttpPath=true"
)

echo "git-commit: cloning ${REPO_NAME} into temp dir"

# Clone repo (shallow). If empty repo, init fresh.
if ! git "${GIT_CC[@]}" clone --depth 1 "$REPO_URL" "$WORK_DIR/repo" 2>/dev/null; then
  echo "git-commit: empty repo detected, initializing"
  mkdir -p "$WORK_DIR/repo"
  cd "$WORK_DIR/repo"
  git init
  git checkout -b main
  git remote add origin "$REPO_URL"
else
  cd "$WORK_DIR/repo"
fi

# Configure commit identity (repo-local, inside the temp dir)
git config user.name "Platformer Archivist"
git config user.email "archivist@platformer.local"

# Remove all tracked content except .git/ (so deletions in archive are reflected)
find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

# Extract archive flat at root (strip the top-level directory)
tar -xzf "$ARCHIVE_PATH" --strip-components=1 -C .

# Stage all changes
git add -A

# Check for actual changes
if git diff --cached --quiet 2>/dev/null; then
  echo "git-commit: no changes to commit (archive matches HEAD)"
  exit 0
fi

# Commit with descriptive message
git commit -m "archive: ${ARCHIVE_BASENAME}" -m "Source: platformer archivist module
Archive: ${ARCHIVE_BASENAME}.tar.gz
Committed-by: git-commit.sh"

# Push current HEAD to remote main (agnostic about local branch name)
if git remote get-url origin &>/dev/null; then
  git "${GIT_CC[@]}" push -u origin HEAD:refs/heads/main
fi

echo "git-commit: committed ${ARCHIVE_BASENAME} to ${REPO_NAME}"
