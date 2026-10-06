"""arcbot KB sync daemon

Keeps the Bedrock Knowledge Base in step with local document sources. Every
SYNC_INTERVAL seconds it enumerates the configured source trees, uploads new
and changed files to the KB documents bucket, deletes objects whose source
file is gone, and - when anything changed - runs an ingestion job and waits
for it to finish, logging the job's statistics and per-document failures.

File selection and S3 key mapping mirror scripts/kb-upload.sh (the apply-time
path used when the daemon is off), so either one can own the bucket without
re-uploading everything:
  - git checkouts contribute tracked files only ('git ls-files'); other
    directories are walked, skipping .git/ and .terraform/
  - SUPPORTED_EXTS upload as-is, REMAP_EXTS upload with a .txt suffix so
    Bedrock parses them as text, and everything else is skipped
  - keys are "<prefix>/<path relative to the source root>"

Changes are detected by comparing local MD5s against S3 ETags (the bucket uses
SSE-S3 and every upload here is a single PUT, so the ETag is the MD5). Hashes
are cached by (size, mtime), so a quiet pass only stats files.

Environment variables (set by the Terraform-generated compose file):
    BUCKET             KB documents bucket name
    SOURCE_PATHS       JSON array of [source_dir, s3_prefix] pairs
    SUPPORTED_EXTS     JSON array of extensions uploaded as-is
    REMAP_EXTS         JSON array of extensions uploaded with a .txt suffix
    KNOWLEDGE_BASE_ID  Bedrock Knowledge Base to re-index
    DATA_SOURCE_ID     Bedrock data source backed by BUCKET
    SYNC_INTERVAL      Seconds between passes (default 300)
"""

import argparse
import base64
import hashlib
import json
import logging
import mimetypes
import os
import signal
import subprocess
import sys
import time

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("kb-sync")

SKIP_DIRS = {".terraform", ".git"}
POLL_INTERVAL = 15  # seconds between get_ingestion_job calls
ACTIVE_JOB_STATUSES = {"STARTING", "IN_PROGRESS", "STOPPING"}

BUCKET = os.environ["BUCKET"]
SOURCE_PATHS = json.loads(os.environ["SOURCE_PATHS"])
SUPPORTED_EXTS = set(json.loads(os.environ["SUPPORTED_EXTS"]))
REMAP_EXTS = set(json.loads(os.environ["REMAP_EXTS"]))
KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "300"))

mimetypes.add_type("text/markdown", ".md")

# path -> (size, mtime_ns, md5 hex), so unchanged files are never re-read.
_md5_cache = {}


# ── Local sources ────────────────────────────────────────────────────────────


def list_source(root):
    """Enumerate one source tree as {relative_path: full_path}.

    Returns None when the tree can't be enumerated reliably (git failed in a
    checkout, or nothing was found - e.g. a missing or emptied mount), so the
    caller never mistakes an unreadable source for deleted files.
    """
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True,
        )
        rels = [p for p in result.stdout.decode("utf-8", "surrogateescape").split("\0") if p]
    except (subprocess.CalledProcessError, OSError) as exc:
        if os.path.exists(os.path.join(root, ".git")):
            stderr = (getattr(exc, "stderr", None) or b"").decode(errors="replace").strip()
            logger.error("git ls-files failed in %s: %s", root, stderr or exc)
            return None
        # Not a git checkout: walk it, like kb-upload.sh does.
        rels = []
        for dirpath, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            rels.extend(os.path.relpath(os.path.join(dirpath, f), root) for f in files)

    # isfile() drops submodule directories and files deleted but still indexed.
    files = {rel: os.path.join(root, rel) for rel in rels if os.path.isfile(os.path.join(root, rel))}
    if not files:
        logger.error("No files found in %s - skipping it this pass", root)
        return None
    return files


def scan_sources():
    """Map every file that belongs in the bucket as {s3_key: full_path}.

    The second value is False when any source couldn't be enumerated, which
    makes deletions unsafe for this pass.
    """
    desired = {}
    complete = True
    for root, prefix in SOURCE_PATHS:
        files = list_source(root)
        if files is None:
            complete = False
            continue
        for rel, full in files.items():
            ext = os.path.splitext(rel)[1].lower()
            key = f"{prefix}/{rel}".lstrip("/")
            if ext not in SUPPORTED_EXTS:
                if ext not in REMAP_EXTS:
                    continue
                key = f"{key}.txt"
            desired[key] = full
    return desired, complete


def file_md5(path):
    st = os.stat(path)
    cached = _md5_cache.get(path)
    if cached and cached[:2] == (st.st_size, st.st_mtime_ns):
        return cached[2]
    digest = hashlib.md5(usedforsecurity=False)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    _md5_cache[path] = (st.st_size, st.st_mtime_ns, digest.hexdigest())
    return digest.hexdigest()


# ── S3 ───────────────────────────────────────────────────────────────────────


def list_bucket(s3):
    """Current bucket contents as {key: etag}."""
    objects = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
        for obj in page.get("Contents", []):
            objects[obj["Key"]] = obj["ETag"].strip('"')
    return objects


def upload(s3, key, path):
    with open(path, "rb") as f:
        body = f.read()
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=body,
        ContentMD5=base64.b64encode(hashlib.md5(body, usedforsecurity=False).digest()).decode(),
        ContentType=mimetypes.guess_type(key)[0] or "application/octet-stream",
    )


def sync(s3, dry_run=False):
    """Bring the bucket in line with the sources. Returns (uploaded, deleted) key lists."""
    desired, complete = scan_sources()
    remote = list_bucket(s3)

    uploads = []
    for key, path in sorted(desired.items()):
        try:
            if remote.get(key) != file_md5(path):
                uploads.append(key)
        except OSError as exc:
            # Vanished mid-scan (e.g. a checkout in progress). It stays in
            # `desired`, so its object isn't deleted; the next pass retries.
            logger.warning("Skipping %s this pass: %s", path, exc)

    if complete:
        deletes = sorted(set(remote) - set(desired))
    else:
        deletes = []
        logger.warning("Skipping deletions this pass: not every source could be enumerated")

    verb = "Would upload" if dry_run else "Uploading"
    for key in uploads:
        logger.info("%s %s", verb, key)
        if not dry_run:
            upload(s3, key, desired[key])

    for key in deletes:
        logger.info("%s %s", "Would delete" if dry_run else "Deleting", key)
    if not dry_run:
        for i in range(0, len(deletes), 1000):
            resp = s3.delete_objects(
                Bucket=BUCKET,
                Delete={"Objects": [{"Key": k} for k in deletes[i:i + 1000]], "Quiet": True},
            )
            for err in resp.get("Errors", []):
                logger.error("Delete failed for %s: %s", err.get("Key"), err.get("Message"))

    return uploads, deletes


# ── Ingestion ────────────────────────────────────────────────────────────────


def failure_reasons(job):
    """Flatten failureReasons - Bedrock packs per-document errors into JSON-encoded lists."""
    for reason in job.get("failureReasons", []):
        try:
            parsed = json.loads(reason)
        except ValueError:
            parsed = reason
        for item in parsed if isinstance(parsed, list) else [parsed]:
            yield str(item)[:400]


def ingest(agent, description):
    """Run an ingestion job to completion. Returns True once the index reflects the bucket."""
    try:
        job = agent.start_ingestion_job(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            dataSourceId=DATA_SOURCE_ID,
            description=description[:200],
        )["ingestionJob"]
    except ClientError as exc:
        # Most often another job (console, terraform apply) is still running.
        logger.warning("Could not start ingestion, will retry next pass: %s", exc)
        return False

    job_id = job["ingestionJobId"]
    logger.info("Ingestion job %s started (%s)", job_id, description)
    start = time.monotonic()
    while job["status"] in ACTIVE_JOB_STATUSES:
        time.sleep(POLL_INTERVAL)
        job = agent.get_ingestion_job(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            dataSourceId=DATA_SOURCE_ID,
            ingestionJobId=job_id,
        )["ingestionJob"]

    stats = job.get("statistics", {})
    logger.info(
        "Ingestion job %s %s in %ds: %d scanned, %d new, %d modified, %d deleted, %d failed",
        job_id, job["status"], time.monotonic() - start,
        stats.get("numberOfDocumentsScanned", 0),
        stats.get("numberOfNewDocumentsIndexed", 0),
        stats.get("numberOfModifiedDocumentsIndexed", 0),
        stats.get("numberOfDocumentsDeleted", 0),
        stats.get("numberOfDocumentsFailed", 0),
    )
    for reason in failure_reasons(job):
        logger.warning("  %s", reason)
    return job["status"] == "COMPLETE"


# ── Main loop ────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Sync KB documents to S3 and re-index on change.")
    parser.add_argument("--once", action="store_true", help="run a single pass and exit")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="log what would be uploaded or deleted, then exit without changing anything",
    )
    args = parser.parse_args()

    # PID 1 in a container ignores SIGTERM unless a handler is installed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    s3 = boto3.client("s3")
    agent = boto3.client("bedrock-agent")
    logger.info(
        "Syncing %s to s3://%s every %ds (kb=%s, ds=%s)",
        ", ".join(root for root, _ in SOURCE_PATHS), BUCKET, SYNC_INTERVAL,
        KNOWLEDGE_BASE_ID, DATA_SOURCE_ID,
    )

    # Ingest on the first pass even when the bucket is already current: a
    # previous run may have uploaded changes and stopped before indexing them.
    stale = True
    while True:
        try:
            uploads, deletes = sync(s3, dry_run=args.dry_run)
            if args.dry_run:
                logger.info("Dry run: %d to upload, %d to delete", len(uploads), len(deletes))
                return
            if uploads or deletes:
                logger.info("Synced %d upload(s), %d deletion(s)", len(uploads), len(deletes))
                stale = True
            if stale:
                stale = not ingest(agent, f"kb-sync: {len(uploads)} uploaded, {len(deletes)} deleted")
        except Exception:
            logger.exception("Sync pass failed, retrying in %ds", SYNC_INTERVAL)
            stale = True
        if args.once:
            return
        time.sleep(SYNC_INTERVAL)


if __name__ == "__main__":
    main()
