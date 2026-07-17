#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/ai-subtitle-self-tests"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcrun --sdk macosx swiftc \
  "$ROOT/Tests/AISubtitleSelfTests/Support.swift" \
  "$ROOT/iina/AISubtitleCore.swift" \
  "$ROOT/iina/AISubtitleFile.swift" \
  "$ROOT/iina/AISubtitleAudioExtractor.swift" \
  "$ROOT/iina/AISubtitleScheduler.swift" \
  "$ROOT/iina/AISubtitleCloudProvider.swift" \
  "$ROOT/iina/AISubtitleAliyunProvider.swift" \
  "$ROOT/iina/WhisperCppAISubtitleProvider.swift" \
  "$ROOT/iina/AppleAISubtitleProvider.swift" \
  "$ROOT/Tests/AISubtitleSelfTests/main.swift" \
  -o "$OUTPUT"

"$OUTPUT"
