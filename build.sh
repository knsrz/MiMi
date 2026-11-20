#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
project="$PWD"
sdk="$(scripts/sdk.sh)"
sparkle="$(scripts/sparkle.sh)"
mkdir -p "$project/.build" "$project/dist"
staging="$(mktemp -d "$project/.build/bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/MiMi.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$staging/Inkfolio.iconset"
# Release builds include both Apple Silicon and Intel; ARCHS=arm64 speeds up local development.
read -r -a architectures <<< "${ARCHS:-arm64 x86_64}"
for architecture in "${architectures[@]}"; do
    [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { echo "Unsupported architecture: $architecture" >&2; exit 1; }
    /usr/bin/xcrun swiftc -sdk "$sdk" -O -swift-version 5 -target "$architecture-apple-macosx14.0" \
        -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -parse-as-library Sources/Inkfolio/*.swift -o "$staging/Inkfolio-$architecture"
done
binaries=()
for architecture in "${architectures[@]}"; do binaries+=("$staging/Inkfolio-$architecture"); done
/usr/bin/lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Inkfolio"
/usr/bin/ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
/usr/bin/xcrun swift -sdk "$sdk" scripts/draw-icon.swift "$staging/Inkfolio.iconset"
/usr/bin/iconutil -c icns "$staging/Inkfolio.iconset" -o "$app/Contents/Resources/Inkfolio.icns"
cp -R Sources/Inkfolio/Resources/KaTeX "$app/Contents/Resources/"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
# Preserve the upstream framework's nested signatures; sign the outer application locally.
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
destination="$project/dist/MiMi.app"
if [[ -e "$destination" ]]; then mv "$destination" "$staging/Previous.app"; fi
if ! mv "$app" "$destination"; then
    if [[ -e "$staging/Previous.app" ]]; then mv "$staging/Previous.app" "$destination"; fi
    exit 1
fi
printf '%s\n' "$destination"
