#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer}"
ANDROID_JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
IOS_DERIVED_DATA="/tmp/GetOverHereWiFiAwareDerived"
IOS_MODULE_CACHE="/tmp/GetOverHereWiFiAwareModuleCache"

if [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "error: xcodebuild not found under $XCODE_DEVELOPER_DIR" >&2
    exit 1
fi

if [[ ! -x "$ANDROID_JAVA_HOME/bin/java" ]]; then
    echo "error: Java not found under $ANDROID_JAVA_HOME" >&2
    exit 1
fi

if [[ ! -x "$PROJECT_ROOT/Android/gradlew" ]]; then
    echo "error: Android Gradle wrapper is missing" >&2
    exit 1
fi

echo "[1/4] iOS device compile"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
CLANG_MODULE_CACHE_PATH="$IOS_MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$IOS_MODULE_CACHE" \
    xcodebuild -quiet \
    -project "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj" \
    -scheme GetOverHere \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

echo "[2/4] iOS focused unit tests"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
CLANG_MODULE_CACHE_PATH="$IOS_MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$IOS_MODULE_CACHE" \
    xcodebuild -quiet \
    -project "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj" \
    -scheme GetOverHere \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    test \
    -only-testing:GetOverHereTests/WiFiAwareProbeFrameTests \
    -only-testing:GetOverHereTests/ListenerOutputTests

echo "[3/4] Android wire-format tests"
(
    cd "$PROJECT_ROOT/Android"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew testDebugUnitTest
)

echo "[4/4] Android debug APK"
(
    cd "$PROJECT_ROOT/Android"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew assembleDebug
)

echo "Wi-Fi Aware lab verification passed"
