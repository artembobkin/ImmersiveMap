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

run_xcodebuild() {
    # `set -o pipefail` above is what makes the pipe safe: without it a failing
    # xcodebuild piped into a formatter reports success, which is the exact
    # class of silently green CI this suite exists to prevent.
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
}

# A failure reaches the formatted log as "Command SwiftCompile failed with a
# nonzero exit code" or a bare list of test names, and nothing else: the
# diagnostics live in the result bundle, and reading them meant downloading an
# artifact. Print them here so a red job says what broke and why.
#
# Build errors and test failures live in different reports, so both are asked
# for: a compile error leaves the test report empty, and a failed assertion
# leaves the build report empty.
report_errors() {
    [ -d "${result_bundle}" ] || return 0

    echo "::group::Build errors from ${result_bundle}"
    xcrun xcresulttool get build-results --path "${result_bundle}" 2>/dev/null \
        | jq -r '.errors[]? | "\(.issueType // "Error"): \(.message)\n  \(.sourceURL // "no source location")"' \
        || echo "Could not read the build report"
    echo "::endgroup::"

    echo "::group::Test failures from ${result_bundle}"
    xcrun xcresulttool get test-results summary --path "${result_bundle}" 2>/dev/null \
        | jq -r '.testFailures[]? | "\(.testIdentifierString)\n  \(.failureText)"' \
        || echo "Could not read the test report"
    echo "::endgroup::"
}

if run_xcodebuild; then
    exit 0
fi
report_errors
exit 1
