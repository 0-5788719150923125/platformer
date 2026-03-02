#!/usr/bin/env bash
# Uploads KB documents to S3 with extension-aware handling:
#   - Files matching SUPPORTED_EXTS are uploaded as-is.
#   - Files matching REMAP_EXTS are uploaded with a .txt suffix so Bedrock
#     can parse content that would otherwise be an unsupported file type.
#   - All other files are skipped.
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
#   SUPPORTED_EXTS  JSON array of extensions to upload as-is (e.g. [".md",".txt"])
#   REMAP_EXTS      JSON array of extensions to remap to .txt  (e.g. [".tf",".hcl"])
set -euo pipefail

python3 - <<'PYEOF'
import json
import os
import shutil
import subprocess
import sys
import tempfile

SKIP_DIRS = {".terraform", ".git"}
SKIP_EXTS = {".sample", ".idx", ".rev", ".pack"}

bucket        = os.environ["BUCKET"]
source_paths  = json.loads(os.environ["SOURCE_PATHS"])  # [[abs_path, s3_prefix], ...]
supported_ext = set(json.loads(os.environ["SUPPORTED_EXTS"]))
remap_ext     = set(json.loads(os.environ["REMAP_EXTS"]))


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
            return [(os.path.join(abs_path, f), f) for f in files]
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

            if ext in supported_ext:
                pass  # key stays as-is
            elif ext in remap_ext:
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
