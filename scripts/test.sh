#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
sdk="$(scripts/sdk.sh)"
mkdir -p .build
/usr/bin/xcrun swiftc -sdk "$sdk" -swift-version 5 -D INKFOLIO_TESTS -parse-as-library \
    Sources/Inkfolio/Library.swift Sources/Inkfolio/LibraryStore.swift Sources/Inkfolio/FolderVault.swift Sources/Inkfolio/VaultAccess.swift Sources/Inkfolio/Manuscript.swift Sources/Inkfolio/Equations.swift Sources/Inkfolio/FileTransfer.swift \
    Sources/Inkfolio/WorkspaceSizing.swift Sources/Inkfolio/EditorFont.swift Sources/Inkfolio/EditorMarkdown.swift Sources/Inkfolio/EditorLayout.swift \
    Tests/InkfolioTests/*.swift -o .build/inkfolio-tests
.build/inkfolio-tests
