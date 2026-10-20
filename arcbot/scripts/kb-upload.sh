#!/usr/bin/env bash
# Uploads KB documents to S3 with extension-aware handling:
#   - Files matching EXCLUDE_PATTERNS are skipped.
#   - Files matching SUPPORTED_EXTS are uploaded as-is.
#   - Any other file that reads as UTF-8 text is uploaded with a .txt suffix
#     so Bedrock can parse content that would otherwise be an unsupported
#     file type. Binary files are skipped.
#
# File discovery respects .gitignore: directories managed by git use
# 'git ls-files' to enumerate tracked files only. Non-git directories
# fall back to os.walk (excluding .terraform/ and .git/).
#
# Uses a staging directory + 'aws s3 sync --delete' for incremental uploads.
# Only changed files are uploaded; orphaned S3 objects are removed. Hard links
# preserve source file mtimes so sync compares correctly (instant, no copies).
#
# Environment variables (set by Terraform provisioner):
#   BUCKET          S3 bucket name
#   SOURCE_PATHS    JSON array of [abs_path, s3_prefix] pairs
#   SUPPORTED_EXTS    JSON array of extensions to upload as-is (e.g. [".md",".txt"])
#   EXCLUDE_PATTERNS  JSON array of globs for files never uploaded (e.g. ["package-lock.json"])
set -euo pipefail

python3 - <<'PYEOF'
import codecs
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile

SKIP_DIRS = {".terraform", ".git"}
SKIP_EXTS = {".sample", ".idx", ".rev", ".pack"}

bucket           = os.environ["BUCKET"]
source_paths     = json.loads(os.environ["SOURCE_PATHS"])  # [[abs_path, s3_prefix], ...]
supported_ext    = set(json.loads(os.environ["SUPPORTED_EXTS"]))
exclude_patterns = json.loads(os.environ.get("EXCLUDE_PATTERNS", "[]"))


def list_files(abs_path):
    """Enumerate files under abs_path, respecting .gitignore when available.

    Uses 'git ls-files' for git-managed directories so that gitignored paths
    (build artifacts, virtual environments, etc.) are never indexed. Falls back
    to os.walk for directories that are not inside a git repository.

    Returns a list of (full_path, rel_path) tuples.
    """
    try:
        result = subprocess.run(
            ["git", "ls-files"],
            cwd=abs_path,
            capture_output=True,
            text=True,
            check=True,
        )
        files = [line for line in result.stdout.splitlines() if line]
        if files:
            # Filter out files deleted from disk but still in the git index
            return [(os.path.join(abs_path, f), f) for f in files if os.path.isfile(os.path.join(abs_path, f))]
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        pass

    # Fallback: os.walk for non-git directories
    entries = []
    for root, dirs, files in os.walk(abs_path):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for filename in sorted(files):
            full = os.path.join(root, filename)
            rel  = os.path.relpath(full, abs_path)
            entries.append((full, rel))
    return entries


def is_excluded(key):
    """Match exclude_patterns like .gitignore: a pattern containing '/' matches
    the whole key, any other pattern matches the file name in any directory."""
    name = key.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatchcase(key if "/" in p else name, p) for p in exclude_patterns)


def is_text(path):
    """git's binary test (a NUL in the first 8000 bytes), plus the sample must
    decode as UTF-8. A character cut off by the sample limit doesn't count."""
    with open(path, "rb") as f:
        head = f.read(8000)
    if b"\0" in head:
        return False
    try:
        codecs.getincrementaldecoder("utf-8")().decode(head, final=len(head) < 8000)
    except UnicodeDecodeError:
        return False
    return True


# Phase 1: Hard-link files into staging directory.
staging_dir = tempfile.mkdtemp(prefix="kb-staging-")
staged  = 0
skipped = 0

try:
    for abs_path, prefix in source_paths:
        for full, rel in list_files(abs_path):
            _, ext = os.path.splitext(rel)
            ext = ext.lower()

            if ext in SKIP_EXTS:
                continue

            key = f"{prefix}/{rel}".lstrip("/")

            if is_excluded(key):
                skipped += 1
                continue
            elif ext in supported_ext:
                pass  # key stays as-is
            elif is_text(full):
                key = f"{key}.txt"
            else:
                skipped += 1
                continue

            staging_path = os.path.join(staging_dir, key)
            os.makedirs(os.path.dirname(staging_path), exist_ok=True)
            try:
                os.link(full, staging_path)
            except OSError:
                shutil.copy2(full, staging_path)
            staged += 1

    print(f"Staged {staged} files ({skipped} skipped). Syncing to s3://{bucket}/ ...")

    # Phase 2: Incremental sync — uploads only changed files, removes orphans.
    result = subprocess.run(
        ["aws", "s3", "sync", staging_dir + "/", f"s3://{bucket}/", "--delete"],
        capture_output=True, text=True,
    )
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(result.returncode)

    print("Sync complete.")
finally:
    # Phase 3: Cleanup staging directory.
    subprocess.run(["rm", "-rf", staging_dir])
PYEOF
