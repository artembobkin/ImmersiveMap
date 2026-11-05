#!/bin/sh
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
#
# Compiles the engine's shaders into one Metal library, for the platform the
# build is for. Run by `MetalLibraryPlugin` as
#
#   compile-metal-library.sh <library> <module cache> <shader>...
#
# Xcode sets its build settings in the environment: PLATFORM_NAME, the
# deployment targets, SDKROOT (which `xcrun` reads) and MTL_ENABLE_DEBUG_INFO.
# SwiftPM's command line builds for the host and sets SDKROOT alone, so a
# missing PLATFORM_NAME means macOS. The fallback deployment targets are the
# package's own (`platforms` in Package.swift).
#
# The library is written through a temporary file, so a failed compile leaves
# none behind for the build to take.

set -eu

library="$1"
module_cache="$2"
shift 2

case "${PLATFORM_NAME:-macosx}" in
    macosx) target="air64-apple-macos${MACOSX_DEPLOYMENT_TARGET:-15.0}" ;;
    iphoneos) target="air64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-18.0}" ;;
    iphonesimulator) target="air64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-18.0}-simulator" ;;
    *)
        echo "error: ImmersiveMap's shaders build for macOS and iOS, not for ${PLATFORM_NAME}" >&2
        exit 1
        ;;
esac

# Xcode's setting for the shaders' debug information: the Debug build of an
# app keeps the shader sources for the GPU debugger.
case "${MTL_ENABLE_DEBUG_INFO:-NO}" in
    INCLUDE_SOURCE) set -- -gline-tables-only -frecord-sources "$@" ;;
    YES) set -- -gline-tables-only "$@" ;;
esac

mkdir -p "$(dirname "$library")"
/usr/bin/xcrun metal -target "$target" -fmodules-cache-path="$module_cache" -o "$library.partial" "$@"
mv -f "$library.partial" "$library"
