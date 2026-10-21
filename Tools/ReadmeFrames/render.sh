#!/usr/bin/env bash
# Renders the README's frames: builds the tool through xcodebuild, which
# compiles the engine's Metal shaders into the resource bundle (a plain
# `swift run` ships the shader sources only, and the capture cannot draw),
# then runs it with the arguments given.
#
#   Tools/ReadmeFrames/render.sh                       # every frame of frames.json into Assets/
#   Tools/ReadmeFrames/render.sh --only readme-globe-europe
#   Tools/ReadmeFrames/render.sh --frames my.json --out /tmp/frames --settle 90
#
# The build lands in Tools/ReadmeFrames/.build/xcode (ignored by git).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
xcodebuild -scheme ReadmeFrames -destination 'platform=macOS' -configuration Release \
  -derivedDataPath .build/xcode build -quiet
exec .build/xcode/Build/Products/Release/readme-frames "$@"
