#!/bin/bash
# Generate native Android packets on the selected device and decode them in the iOS simulator.
# The retained fixture is updated explicitly, never replaced by this verification gate.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEC_JAVA="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
CODEC_ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
CODEC_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
CODEC_FIXTURE="${GOH_ANDROID_CODEC_FIXTURE:-/tmp/GetOverHere-android-native-codec.hex}"
[[ -x "$CODEC_JAVA/bin/java" && -x "$CODEC_ADB" ]] || { echo 'error: Java/adb unavailable' >&2; exit 1; }
[[ "$("$CODEC_ADB" -s "$CODEC_SERIAL" get-state)" == device ]] || { echo 'error: Android unavailable' >&2; exit 1; }
JAVA_HOME="$CODEC_JAVA" "$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" \
    :app:assembleDebug :app:assembleDebugAndroidTest
"$CODEC_ADB" -s "$CODEC_SERIAL" install -r "$PROJECT_ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
"$CODEC_ADB" -s "$CODEC_SERIAL" install -r "$PROJECT_ROOT/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
CODEC_RESULT="$("$CODEC_ADB" -s "$CODEC_SERIAL" shell am instrument -w -r \
    -e class com.aessam.comeoverhere.NativeRealtimeAudioCodecTest#exportsProductionAndroidPackets \
    com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner)"
echo "$CODEC_RESULT"
[[ "$CODEC_RESULT" == *'OK (1 test)'* ]] || { echo 'error: Android codec export test failed' >&2; exit 1; }
"$CODEC_ADB" -s "$CODEC_SERIAL" exec-out run-as com.aessam.comeoverhere cat files/android-native-codec.hex > "$CODEC_FIXTURE"
[[ -s "$CODEC_FIXTURE" ]] || { echo 'error: Android codec fixture is empty' >&2; exit 1; }
if LC_ALL=C grep -qEv '^[0-9a-f]+$' "$CODEC_FIXTURE"; then
    echo 'error: Android codec fixture contains non-hex output' >&2; exit 1
fi
CODEC_DERIVED="${GOH_IOS_DERIVED_DATA:-/tmp/GetOverHereReverseCodecIOS}"
CODEC_DESTINATION="${GOH_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
xcodebuild \
    -project "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj" -scheme GetOverHere \
    -destination "$CODEC_DESTINATION" \
    -derivedDataPath "$CODEC_DERIVED" \
    -parallel-testing-enabled NO \
    build-for-testing
# Set the test process environment explicitly; xcodebuild does not guarantee forwarding
# arbitrary shell variables to a launched test host. Edit only the generated test manifest.
CODEC_MANIFESTS=("$CODEC_DERIVED"/Build/Products/GetOverHere_GetOverHere_iphonesimulator*-arm64.xctestrun)
[[ ${#CODEC_MANIFESTS[@]} == 1 && -f "${CODEC_MANIFESTS[0]}" ]] || { echo 'error: expected one simulator test manifest; use a dedicated derived-data path' >&2; exit 1; }
CODEC_TEMP="$(mktemp "$CODEC_DERIVED/Build/Products/reverse-codec.XXXXXX")"
CODEC_WORKING="$CODEC_TEMP.xctestrun"
mv "$CODEC_TEMP" "$CODEC_WORKING"
trap 'rm -f "$CODEC_WORKING"' EXIT
# Keep __TESTROOT__ relative paths valid by storing the copy beside the original.
cp "${CODEC_MANIFESTS[0]}" "$CODEC_WORKING"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:BlueprintName' "$CODEC_WORKING")" == GetOverHereTests ]] || { echo 'error: unexpected test manifest target' >&2; exit 1; }
plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_ANDROID_CODEC_FIXTURE -string "$CODEC_FIXTURE" "$CODEC_WORKING"
xcodebuild -xctestrun "$CODEC_WORKING" -destination "$CODEC_DESTINATION" -parallel-testing-enabled NO \
    test-without-building -only-testing:GetOverHereTests/NativeRealtimeAudioCodecTests
echo "Android-to-iOS native codec gate passed ($CODEC_SERIAL; $CODEC_FIXTURE)"
