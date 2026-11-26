#!/usr/bin/env bash
# Build the lazy provider proxy (lazyprovider/) and install it for Terraform.
#
# Platformer declares its clouds through platformer.local/lazyprovider/<cloud>
# providers: small proxies in front of the real providers that only set them up
# when a workspace enables them (see lazyprovider/README.md). The .local host
# means "built on this machine": Terraform finds them in ~/.terraform.d/plugins,
# and without a build it can't fetch a provider of that name from anywhere. Terraform can't build them during
# `terraform init`, so run this once per proxy version, then `terraform init`.
#
# No system Go needed: a pinned Go toolchain is downloaded (checksum-verified)
# into ~/.cache/platformer, along with Go's module and build caches. The binary
# is installed into ~/.terraform.d/plugins, which Terraform searches for every
# working directory (the root and module tests alike).
#
# Usage: scripts/build-providers.sh
# After rebuilding the same version: terraform init -upgrade (the lock file pins
# provider packages by hash).

set -euo pipefail

GO_VERSION="1.27.4"

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/lazyprovider"
version="$(tr -d '[:space:]' < "$src/VERSION")"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/platformer"
plugins="${TF_PLUGINS_DIR:-$HOME/.terraform.d/plugins}"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

goroot="$cache/go$GO_VERSION"
if [[ ! -x $goroot/bin/go ]]; then
  file="go$GO_VERSION.$os-$arch.tar.gz"
  echo "Fetching Go $GO_VERSION ($os/$arch)..."
  sha="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | python3 -c '
import json, sys
name = sys.argv[1]
for release in json.load(sys.stdin):
    for f in release["files"]:
        if f["filename"] == name:
            print(f["sha256"]); sys.exit(0)
sys.exit("no checksum published for " + name)' "$file")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://go.dev/dl/$file" -o "$tmp/$file"
  echo "$sha  $tmp/$file" | sha256sum -c --quiet -
  mkdir -p "$tmp/x" "$cache"
  tar -xzf "$tmp/$file" -C "$tmp/x"
  rm -rf "$goroot"
  mv "$tmp/x/go" "$goroot"
fi

export PATH="$goroot/bin:$PATH"
export GOPATH="$cache/gopath" GOMODCACHE="$cache/gopath/pkg/mod" GOCACHE="$cache/gocache"
export GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0

cd "$src"
echo "Testing lazyprovider..."
go test ./...
echo "Building lazyprovider $version..."
# Reproducible: the same source and Go version always give the same bytes, so
# re-running this after unrelated commits keeps the lock file's checksums valid.
# (By default Go stamps the git commit into the binary.)
go build -trimpath -buildvcs=false -ldflags='-s -w' -o "$cache/build/lazyprovider" .

for type in $("$cache/build/lazyprovider" -types); do
  dir="$plugins/platformer.local/lazyprovider/$type/$version/${os}_${arch}"
  mkdir -p "$dir"
  install -m 0755 "$cache/build/lazyprovider" "$dir/terraform-provider-${type}_v${version}"
done
echo "Installed platformer.local/lazyprovider/{$("$cache/build/lazyprovider" -types | tr ' ' ',')} $version into $plugins"
echo "Next: terraform init (or terraform init -upgrade after rebuilding the same version)"
