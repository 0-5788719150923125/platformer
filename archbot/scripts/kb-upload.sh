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
# A (source_path, s3_key) index is built in memory first, then all uploads
# run concurrently from their original locations - no staging, no copies.
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
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

SKIP_DIRS   = {".terraform", ".git"}
SKIP_EXTS   = {".sample", ".idx", ".rev", ".pack"}
CONCURRENCY = 10

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


# Build upload index in memory - no file copying.
index   = []
skipped = 0

for abs_path, prefix in source_paths:
    for full, rel in list_files(abs_path):
        _, ext = os.path.splitext(rel)
        ext = ext.lower()

        if ext in SKIP_EXTS:
            continue

        key = f"{prefix}/{rel}".lstrip("/")

        if ext in supported_ext:
            index.append((full, key, []))
        elif ext in remap_ext:
            index.append((full, f"{key}.txt", ["--content-type", "text/plain"]))
        else:
            skipped += 1

print(f"Index: {len(index)} files to upload, {skipped} skipped.")

# Wipe bucket, then upload from source paths in parallel.
subprocess.run(["aws", "s3", "rm", f"s3://{bucket}", "--recursive"], check=True)


def upload(item):
    full, key, extra = item
    subprocess.run(
        ["aws", "s3", "cp", full, f"s3://{bucket}/{key}"] + extra,
        check=True,
        capture_output=True,
    )


errors   = []
uploaded = 0

with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
    futures = {pool.submit(upload, item): item for item in index}
    for future in as_completed(futures):
        try:
            future.result()
            uploaded += 1
            if uploaded % 10 == 0 or uploaded == len(index):
                print(f"  {uploaded}/{len(index)} uploaded...")
        except subprocess.CalledProcessError as exc:
            errors.append(exc.stderr.decode().strip() if exc.stderr else str(exc))

if errors:
    for err in errors:
        print(f"ERROR: {err}", file=sys.stderr)
    sys.exit(1)

print(f"Upload complete: {uploaded} files.")
PYEOF
