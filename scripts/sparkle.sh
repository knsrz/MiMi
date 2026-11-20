#!/bin/bash
# Pinned upstream distribution; private signing keys never live in this directory.
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
root="$PWD/.build/sparkle"
if [[ ! -f "$root/.version" || "$(cat "$root/.version")" != "$version" ]]; then
    mkdir -p .build
    staging="$(mktemp -d "$PWD/.build/sparkle-download.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    curl --fail --location --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$staging/Sparkle.tar.xz"
    echo "$checksum  $staging/Sparkle.tar.xz" | shasum -a 256 --check --status
    mkdir "$staging/unpacked"
    tar -xf "$staging/Sparkle.tar.xz" -C "$staging/unpacked"
    rm -rf "$root"
    mv "$staging/unpacked" "$root"
    echo "$version" > "$root/.version"
fi
printf '%s\n' "$root"
