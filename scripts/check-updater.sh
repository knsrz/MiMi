#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$(scripts/sdk.sh)"
sparkle="$(scripts/sparkle.sh)"
xcrun swiftc -sdk "$sdk" -swift-version 5 -F "$sparkle" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$sparkle" Tests/UpdateProbe/main.swift -o .build/update-probe-tool
.build/update-probe-tool "$PWD/dist/MiMi.app" "$@"
