#!/usr/bin/env bash
# Computes a hash of KB document sources for change detection.
# Uses 'git ls-files' to respect .gitignore (same scope as kb-upload.sh),
# falling back to os.walk for non-git directories. Hash is derived from
# file paths, sizes, and modification times so it stays fast even for
# large directories.
#
# Input (stdin, JSON): {"paths": "[\"path1\", \"path2\"]"}
# Output (stdout, JSON): {"hash": "<md5>"}
set -euo pipefail

# Capture Terraform's query from stdin before the heredoc consumes it.
QUERY=$(cat)

QUERY="$QUERY" python3 - <<'PYEOF'
import hashlib
import json
import os
import subprocess
import sys

SKIP_DIRS = {".terraform", ".git"}
SKIP_EXTS = {".sample", ".idx", ".rev", ".pack"}

data  = json.loads(os.environ["QUERY"])
paths = json.loads(data["paths"])

lines = []

for path in paths:
    try:
        result = subprocess.run(
            ["git", "ls-files"],
            cwd=path,
            capture_output=True,
            text=True,
            check=True,
        )
        files = [line for line in result.stdout.splitlines() if line]
        if files:
            for rel in files:
                full = os.path.join(path, rel)
                try:
                    st = os.stat(full)
                    lines.append(f"{full} {st.st_size} {st.st_mtime}")
                except OSError:
                    pass
            continue
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        pass

    # Fallback: os.walk for non-git directories
    for root, dirs, fs in os.walk(path):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for filename in sorted(fs):
            if os.path.splitext(filename)[1].lower() in SKIP_EXTS:
                continue
            full = os.path.join(root, filename)
            try:
                st = os.stat(full)
                lines.append(f"{full} {st.st_size} {st.st_mtime}")
            except OSError:
                pass

digest = hashlib.md5("\n".join(sorted(lines)).encode()).hexdigest()
print(json.dumps({"hash": digest}))
PYEOF
