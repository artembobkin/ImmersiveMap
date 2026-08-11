#!/bin/bash
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
#
# Runs the package test suite through Xcode, which (unlike `swift test`)
# compiles the .metal sources and therefore actually executes the rendering
# tests.
#
# Usage: run-xcodebuild-test.sh <destination> <result-bundle-prefix>

set -euo pipefail

destination="${1:?destination is required, e.g. platform=macOS}"
prefix="${2:?result bundle prefix is required}"
result_bundle="${prefix}-TestResults.xcresult"

rm -rf "${result_bundle}"

# `set -o pipefail` above is what makes the pipe safe: without it a failing
# xcodebuild piped into a formatter reports success, which is the exact class
# of silently green CI this suite exists to prevent.
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild test \
        -workspace .swiftpm/xcode/package.xcworkspace \
        -scheme ImmersiveMap \
        -destination "${destination}" \
        -resultBundlePath "${result_bundle}" \
        | xcbeautify --renderer github-actions
else
    xcodebuild test \
        -workspace .swiftpm/xcode/package.xcworkspace \
        -scheme ImmersiveMap \
        -destination "${destination}" \
        -resultBundlePath "${result_bundle}"
fi
