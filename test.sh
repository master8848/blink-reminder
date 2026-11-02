#!/bin/bash
# test.sh — pre-ship checks for BlinkReminder (swiftc-only, no Xcode project).
# 1) ./build.sh succeeds + universal archs present
# 2) logic tests via swift Tests.swift
# 3) static check: no 1s background menu polling timer remains
set -euo pipefail
cd "$(dirname "$0")"

echo "=== 1. Build ==="
./build.sh

echo "=== Arch check (arm64 + x86_64) ==="
ARCHS="$(lipo -info BlinkReminder.app/Contents/MacOS/BlinkReminder)"
echo "$ARCHS"
echo "$ARCHS" | grep -q "arm64" || { echo "FAIL: arm64 slice missing"; exit 1; }
echo "$ARCHS" | grep -q "x86_64" || { echo "FAIL: x86_64 slice missing"; exit 1; }

echo "=== 2. Logic tests ==="
swift Tests.swift

echo "=== 3. No 1s background polling ==="
if grep -n "menuTickTimer\|startMenuTick\|tickMenuCountdown" BlinkReminder.swift; then
    echo "FAIL: 1s menu polling timer still present in BlinkReminder.swift"
    exit 1
fi
echo "PASS: no 1s background menu timer"

echo "ALL GREEN"
