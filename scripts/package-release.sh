#!/bin/bash
# Build and sign distributable assets. Does not publish or change the source version.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=knsrz/MiMi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a stable X.Y.Z version.' >&2; exit 1; }
[[ -z "${ARCHS:-}" || "$ARCHS" == 'arm64 x86_64' ]] || { echo 'Releases require both architectures.' >&2; exit 1; }
sparkle="$(scripts/sparkle.sh)"
# Local releases use this Mac's Keychain; CI uses a temporary file removed on exit.
key_args=(--account MiMi-knsrz)
key_file=''
cleanup() { if [[ -n "$key_file" ]]; then rm -f "$key_file"; fi; }
trap cleanup EXIT
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    key_file="$(mktemp)"
    chmod 600 "$key_file"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key_file"
    unset SPARKLE_PRIVATE_KEY
    key_args=(--ed-key-file "$key_file")
else
    public_key="$("$sparkle/bin/generate_keys" --account MiMi-knsrz -p)"
    expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
    [[ "$public_key" == "$expected_key" ]] || { echo 'Wrong update signing key.' >&2; exit 1; }
    key_file="$(mktemp)"
    chmod 600 "$key_file"
    "$sparkle/bin/generate_keys" --account MiMi-knsrz -x "$key_file"
    key_args=(--ed-key-file "$key_file")
fi
./build.sh
./scripts/check-updater.sh
assets="$PWD/dist/release-$version"
# Refuse accidental overwrites of already prepared/signed assets.
[[ ! -e "$assets" ]] || { echo "$assets already exists; move it aside to rebuild." >&2; exit 1; }
mkdir -p "$assets"
archive="MiMi-$version-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/MiMi.app "$assets/$archive"
# DMG is for first installation; Sparkle downloads the signed ZIP to update the app.
staging="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
/usr/bin/ditto dist/MiMi.app "$staging/MiMi.app"
ln -s /Applications "$staging/Applications"
if ! /usr/bin/hdiutil create -volname "MiMi $version" -srcfolder "$staging" -ov -format UDZO "$assets/MiMi-$version-universal.dmg"; then
    rm -rf "$staging"; exit 1
fi
rm -rf "$staging"
# Only the ZIP belongs in the appcast; DMG must not produce a second entry.
feed_dir="$(mktemp -d "$PWD/.build/feed.XXXXXX")"
cp "$assets/$archive" "$feed_dir/"
if ! "$sparkle/bin/generate_appcast" "${key_args[@]}" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --link "https://github.com/$repo/releases/tag/v$version" "$feed_dir"; then
    rm -rf "$feed_dir"; exit 1
fi
cp "$feed_dir/appcast.xml" "$assets/appcast.xml"
rm -rf "$feed_dir"
"$sparkle/bin/sign_update" "${key_args[@]}" --verify "$assets/appcast.xml"
python3 scripts/verify-release.py "$assets"
(cd "$assets" && shasum -a 256 "$archive" "MiMi-$version-universal.dmg" appcast.xml > SHA256SUMS)
printf 'Release assets: %s\n' "$assets"
