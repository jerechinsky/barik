#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -o build/tests/spaces-refresh-tests \
    Barik/Widgets/Spaces/SpacesModels.swift \
    Barik/Widgets/Spaces/SpacesViewModel.swift \
    Barik/Widgets/Spaces/Yabai/YabaiModels.swift \
    Barik/Widgets/Spaces/Yabai/YabaiProvider.swift \
    Barik/Widgets/Spaces/Aerospace/AerospaceModels.swift \
    Barik/Widgets/Spaces/Aerospace/AerospaceProvider.swift \
    Tests/SpacesRefreshTests.swift
build/tests/spaces-refresh-tests
