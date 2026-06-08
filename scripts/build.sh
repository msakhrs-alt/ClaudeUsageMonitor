#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "=== XcodeGen でプロジェクト生成 ==="
xcodegen generate

echo "=== ビルド (arm64) ==="
xcodebuild -project ClaudeUsageMonitor.xcodeproj \
           -scheme ClaudeUsageMonitor \
           -configuration Release \
           -arch arm64 \
           CONFIGURATION_BUILD_DIR=./build/arm64 \
           CODE_SIGN_IDENTITY="-" \
           | xcpretty 2>/dev/null || true

echo "=== 完了: ./build/arm64/ClaudeUsageMonitor.app ==="
