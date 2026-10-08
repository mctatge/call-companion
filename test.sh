#!/bin/bash
set -euo pipefail
COMPANION_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$COMPANION_DIR/.build"
DEVELOPER_ROOT="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
SWIFTC="${SWIFTC:-$DEVELOPER_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDKROOT="${SDKROOT:-$DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
mkdir -p "$BUILD_DIR/module-cache"
FLAGS=(-swift-version 5 -O -target arm64-apple-macosx26.0 -sdk "$SDKROOT" -module-cache-path "$BUILD_DIR/module-cache")
"$SWIFTC" "${FLAGS[@]}" "$COMPANION_DIR/ProjectContext.swift" "$COMPANION_DIR/ProjectContextTests.swift" -o "$BUILD_DIR/context-tests"
"$BUILD_DIR/context-tests"
"$SWIFTC" "${FLAGS[@]}" "$COMPANION_DIR/Models.swift" "$COMPANION_DIR/ProjectContext.swift" "$COMPANION_DIR/AnswerEngine.swift" "$COMPANION_DIR/AnswerEngineTests.swift" -o "$BUILD_DIR/answer-tests"
"$BUILD_DIR/answer-tests"
"$SWIFTC" "${FLAGS[@]}" "$COMPANION_DIR/Models.swift" "$COMPANION_DIR/ProjectContext.swift" "$COMPANION_DIR/SpeechCapture.swift" "$COMPANION_DIR/TranscriptionBenchmark.swift" "$COMPANION_DIR/AnswerEngine.swift" "$COMPANION_DIR/Smoke.swift" -o "$BUILD_DIR/smoke"
"$BUILD_DIR/smoke"
"$SWIFTC" "${FLAGS[@]}" -parse-as-library "$COMPANION_DIR/TranscriptionBenchmarkTests.swift" -o "$BUILD_DIR/transcription-benchmark-tests"
"$BUILD_DIR/transcription-benchmark-tests" "$COMPANION_DIR/Fixtures/Transcription/manifest.json"
