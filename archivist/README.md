# Archivist

Produces a scrubbed, versioned tarball of the `platformer/` codebase on every `terraform apply`. The archive is safe to distribute - sensitive strings (AWS account IDs, internal domain names, S3 bucket names, and account-specific targets) are replaced with generic placeholders before packaging.

## Concept

The platformer codebase is itself a training corpus for AI agents (see [Praxis](../applications/ansible/praxis/)). To share it safely and generically, the archivist automates the scrub-and-package pipeline: `git archive` produces a clean snapshot (respecting `.gitignore` and `.gitattributes` export-ignore rules), then a `sed` pass replaces everything sensitive, and the result lands in `archivist/build` as a versioned tarball.

This is always-on, like `auto-docs`. No state fragment is needed to enable it.

## Dependency Graph

```
archivist (git archive + scrub) --> portal (artifact entities in Port.io)
                                \-> storage (repository_requests --> CodeCommit repo)
```

Archivist emits `artifact_requests` via dependency inversion. The portal module consumes these to create catalog entries in Port.io without any direct coupling between the two modules. Archivist also emits `repository_requests` to the storage module, which provisions a CodeCommit repository for git-based archive storage.

## Key Features

- **git archive** - Uses `git archive HEAD platformer/` for a clean export that automatically excludes gitignored files and `.gitattributes export-ignore` entries. `scrub.sed` is also export-ignored so replacement rules are not bundled with the archive.
- **Deterministic naming** - Archive filename includes the ISO date and short git SHA: `platformer-<date>-<sha>.tar.gz`.
- **Idempotent** - The script skips the rebuild if an archive for the current SHA already exists.
- **Scrub rules** - Defined in `scrub.sed` (excluded from the archive itself). Easy to audit and extend. Applied to `.tf`, `.yaml`, `.yml`, `.sh`, `.md`, `.json`, `.hcl`, `.j2` files.
- **Module source rewriting** - After scrubbing, all local module `source` references (`"./module"`, `"../module"`) are rewritten to pinned git refs: `git::https://github.com/acme-sandbox/platformer//platformer/<module>?ref=<full-sha>`. The archive is self-contained - consumers do not need the original repo layout.
- **Artifacts registry** - Emits structured `artifact_requests` outputs (types: `archive`, `git-repository`) consumed by the portal module.
- **Git storage** - Commits scrubbed archive contents to a CodeCommit repository for ArgoCD-style GitOps workflows (see below).

## Git Storage

When `repo_name` is set, the archivist commits the scrubbed archive contents into a CodeCommit repository after each build. This provides a git-native artifact history suitable for GitOps workflows (e.g., ArgoCD pointing at a CodeCommit repo).

The commit history is independent of the source repository - each commit tracks artifact evolution (new SHA or scrub rule change), not source development history. The `git-commit.sh` script handles:

- HTTPS cloning via the AWS CLI credential helper (no extra packages needed)
- Full content replacement (deletions in the archive are reflected)
- Idempotent commits (no-op if archive matches HEAD)
- Fresh repo initialization (handles empty CodeCommit repos)

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `bucket_name` | S3 bucket name for archive uploads. Empty disables upload. | `""` |
| `repo_name` | CodeCommit repository name for git-based archive storage. Empty disables git commits. | `""` |
| `aws_profile` | AWS CLI profile for S3/CodeCommit commands. | `""` |
| `aws_region` | AWS region for console URLs. | `""` |

## Output Location

Archives are written to `archivist/build/` (git-ignored via `archivist/.gitignore`):

```
platformer/archivist/build/
  platformer-2026-02-23-f25e6b8c.tar.gz
  latest.tar.gz -> platformer-2026-02-23-f25e6b8c.tar.gz
  MANIFEST.txt
```

## Adding Scrub Rules

Edit `scrub.sed`. Each rule is a standard `sed` substitution:

```
s/sensitive-string/generic-replacement/g
```

`scrub.sed` is listed in `.gitattributes` as `export-ignore`, so it is never included in the packaged archive - the replacement rules stay private. Re-running `terraform apply` will trigger a rebuild because `scrub_hash` is part of the `null_resource` trigger.

## Changing the Public Repo URL

The GitHub base URL for module source rewriting is defined at the top of `scripts/archivist.sh`:

```bash
GITHUB_BASE="git::https://github.com/acme-sandbox/platformer//platformer"
```

Update this when the public repo changes. The full commit SHA is appended as `?ref=<sha>` automatically.

## Extending the Artifacts Registry

Other modules can contribute `artifact_requests` in the same format to expose their own artifacts (Docker images, Helm charts, golden AMIs, etc.) in the portal. The root `main.tf` collects and passes them to the portal module.

The schema for each entry:

```hcl
{
  name       = string  # artifact name (e.g., "platformer", "my-image")
  version    = string  # version tag or git SHA
  type       = string  # "archive" | "docker-image" | "helm-chart" | "golden-image" | "git-repository"
  path       = string  # local path or remote URL
  source     = string  # module that produced it (e.g., "archivist", "build")
  created_at = string  # ISO 8601 timestamp
}
```
