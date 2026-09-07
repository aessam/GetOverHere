#!/bin/bash

# Full host gate plus native UI/instrumentation on virtual devices. Hardware-only tests
# report explicit skips; this gate does not qualify physical audio or radio behavior.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
DEVICE_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
XCODE_DEVELOPER_DIR="${GOH_XCODE_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}"
IOS_DERIVED_DATA="${GOH_IOS_DERIVED_DATA:-/tmp/GetOverHereTourSessionDerived}"

[[ -x "$ANDROID_JAVA_HOME/bin/java" ]] || { echo "error: Java not found under $ANDROID_JAVA_HOME" >&2; exit 1; }
[[ -x "$ANDROID_SDK/platform-tools/adb" ]] || { echo "error: adb not found under $ANDROID_SDK" >&2; exit 1; }
[[ -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]] || { echo "error: Xcode not found under $XCODE_DEVELOPER_DIR" >&2; exit 1; }
[[ "$DEVICE_SERIAL" == emulator-* ]] || { echo "error: select an emulator with ANDROID_SERIAL; physical gates run separately" >&2; exit 1; }
[[ "$("$ANDROID_SDK/platform-tools/adb" -s "$DEVICE_SERIAL" get-state)" == device ]] || {
    echo "error: start Android emulator $DEVICE_SERIAL before running this gate" >&2
    exit 1
}

export GOH_ANDROID_JAVA_HOME="$ANDROID_JAVA_HOME"
export GOH_XCODE_DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"

echo "[1/3] Complete host and iOS unit/integration gate"
"$PROJECT_ROOT/scripts/verify_tour_session.sh"

echo "[2/3] iOS Simulator UI suite (physical guide capture is explicitly skipped)"
"$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" -quiet \
    -project "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj" \
    -scheme GetOverHere \
    -destination "${GOH_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    test -only-testing:GetOverHereUITests

echo "[3/3] Android emulator instrumentation (unavailable earpiece checks are explicitly skipped)"
(
    cd "$PROJECT_ROOT/Android"
    ANDROID_SERIAL="$DEVICE_SERIAL" JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew connectedDebugAndroidTest
)

SWIFT_BIN="$(swift build --disable-sandbox --package-path "$PROJECT_ROOT/Packages/TourSessionCore" --scratch-path "${GOH_SWIFT_SCRATCH:-/tmp/GetOverHereTourSessionSwift}" --show-bin-path)/tour-session-swift"
# Gradle can uninstall the instrumentation package after connected tests finish.
"$ANDROID_SDK/platform-tools/adb" -s "$DEVICE_SERIAL" install -r "$PROJECT_ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
"$ANDROID_SDK/platform-tools/adb" -s "$DEVICE_SERIAL" install -r "$PROJECT_ROOT/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
python3 "$PROJECT_ROOT/scripts/verify_guide_signatures_android.py" "$SWIFT_BIN" "$ANDROID_SDK/platform-tools/adb" "$DEVICE_SERIAL"

echo "Virtual-device verification passed; physical audio and radio gates remain separate"
