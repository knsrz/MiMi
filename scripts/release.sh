#!/bin/bash
# Usage: ./scripts/release.sh 1.3.1
# A pushed tag triggers GitHub Actions, which builds and publishes a new Release.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: ./scripts/release.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use X.Y.Z.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit your code changes before releasing.' >&2; exit 1; }
git switch main
git pull --ff-only origin main
git fetch origin --tags
if git rev-parse "v$version" >/dev/null 2>&1; then echo 'Version tag already exists.' >&2; exit 1; fi
./scripts/test.sh
python3 - "$version" <<'PY'
import pathlib, plistlib, sys
p=pathlib.Path('Resources/Info.plist'); x=plistlib.loads(p.read_bytes()); version=sys.argv[1]
parts=lambda v: tuple(map(int,v.split('.')))
if parts(version) <= parts(x['CFBundleShortVersionString']):
    raise SystemExit('New version must be greater than the current version.')
x['CFBundleShortVersionString']=version
x['CFBundleVersion']=str(int(x['CFBundleVersion'])+1)
p.write_bytes(plistlib.dumps(x,sort_keys=False))
PY
git add Resources/Info.plist
git commit -m "Release MiMi $version"
git tag -a "v$version" -m "MiMi $version"
git push --atomic origin main "v$version"
printf 'Build and release progress: https://github.com/knsrz/MiMi/actions\n'
