#!/bin/bash
set -euo pipefail

developer="$(/usr/bin/xcode-select -p)"
if [[ -n "${INKFOLIO_SDK:-}" ]]; then
    printf '%s\n' "$INKFOLIO_SDK"
elif [[ -d "$developer/SDKs/MacOSX.sdk" ]]; then
    printf '%s\n' "$developer/SDKs/MacOSX.sdk"
else
    /usr/bin/xcrun --sdk macosx --show-sdk-path
fi
