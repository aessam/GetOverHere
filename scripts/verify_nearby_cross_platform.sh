#!/bin/bash
# One connected iPhone and one physical Android; both native BLE guide directions.
# No LAN connector is available to either test fixture. Does not alter radio settings.
set -euo pipefail
NEARBY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEARBY_IOS="${GOH_IOS_DEVICE:?Set GOH_IOS_DEVICE to the connected unlocked iPhone UDID}"
NEARBY_ANDROID="${GOH_NEARBY_ANDROID:?Set GOH_NEARBY_ANDROID to the physical Android serial}"
NEARBY_ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
NEARBY_JAVA="${GOH_ANDROID_JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export DEVELOPER_DIR="${GOH_XCODE_DEVELOPER_DIR:-/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer}"
[[ "$NEARBY_ANDROID" != emulator-* && -x "$NEARBY_ADB" && -x "$NEARBY_JAVA/bin/java" ]] || { echo 'error: invalid physical device/toolchain' >&2; exit 1; }
[[ "$("$NEARBY_ADB" -s "$NEARBY_ANDROID" get-state)" == device ]] || { echo 'error: Android unavailable' >&2; exit 1; }
NEARBY_RUN="$(mktemp -d /tmp/GetOverHereNearbyCross.XXXXXX)"
echo "Artifacts: $NEARBY_RUN"
xcrun devicectl device info lockState --device "$NEARBY_IOS" --json-output "$NEARBY_RUN/lock.json" > "$NEARBY_RUN/lock.txt" 2>&1 || {
    echo "error: iPhone developer connection unavailable; $NEARBY_RUN/lock.txt" >&2; exit 1;
}
if rg -q '"passcodeRequired"\s*:\s*true' "$NEARBY_RUN/lock.json"; then
    echo 'error: iPhone must be unlocked for test installation' >&2; exit 1
fi
NEARBY_DERIVED="${GOH_IOS_NEARBY_DERIVED:-/tmp/GetOverHereNearbySigned}"
xcodebuild -quiet -project "$NEARBY_ROOT/iOS/GetOverHere.xcodeproj" -scheme GetOverHere \
    -destination "platform=iOS,id=$NEARBY_IOS" -derivedDataPath "$NEARBY_DERIVED" \
    -parallel-testing-enabled NO build-for-testing > "$NEARBY_RUN/build-ios.txt" 2>&1 || {
    echo "error: signed iOS test build failed; $NEARBY_RUN/build-ios.txt" >&2; exit 1;
}
JAVA_HOME="$NEARBY_JAVA" "$NEARBY_ROOT/Android/gradlew" -p "$NEARBY_ROOT/Android" \
    :app:assembleDebug :app:assembleDebugAndroidTest > "$NEARBY_RUN/build-android.txt" 2>&1
"$NEARBY_ADB" -s "$NEARBY_ANDROID" install -r "$NEARBY_ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
"$NEARBY_ADB" -s "$NEARBY_ANDROID" install -r "$NEARBY_ROOT/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
NEARBY_MANIFESTS=("$NEARBY_DERIVED"/Build/Products/GetOverHere_GetOverHere_iphoneos*.xctestrun)
[[ ${#NEARBY_MANIFESTS[@]} == 1 && -f "${NEARBY_MANIFESTS[0]}" ]] || { echo 'error: expected one device test manifest' >&2; exit 1; }
for role in guide guest; do
    NEARBY_ROOM="$(uuidgen)"
    NEARBY_TEMP="$(mktemp "$NEARBY_DERIVED/Build/Products/nearby-cross.XXXXXX")"
    NEARBY_COPY="$NEARBY_TEMP.xctestrun"
    mv "$NEARBY_TEMP" "$NEARBY_COPY"
    cp "${NEARBY_MANIFESTS[0]}" "$NEARBY_COPY"
    # Generated manifests only: preserve relative __TESTROOT__ paths.
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:BlueprintName' "$NEARBY_COPY")" == GetOverHereTests ]] || { echo 'error: unexpected iOS test target' >&2; exit 1; }
    plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_NEARBY_ROOM -string "$NEARBY_ROOM" "$NEARBY_COPY"
    plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_NEARBY_ROLE -string "$role" "$NEARBY_COPY"
    android_role=guide
    [[ "$role" == guide ]] && android_role=guest
    xcodebuild -quiet -xctestrun "$NEARBY_COPY" -destination "platform=iOS,id=$NEARBY_IOS" \
        -parallel-testing-enabled NO -resultBundlePath "$NEARBY_RUN/ios-$role.xcresult" \
        test-without-building -only-testing:GetOverHereTests/NearbyPhysicalTransportTests \
        > "$NEARBY_RUN/ios-$role.txt" 2>&1 &
    NEARBY_IOS_PID=$!
    "$NEARBY_ADB" -s "$NEARBY_ANDROID" shell am instrument -w -r \
        -e class com.aessam.comeoverhere.NearbyPhysicalTransportTest \
        -e nearbyRole "$android_role" -e nearbyRoom "$NEARBY_ROOM" \
        com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner \
        > "$NEARBY_RUN/android-$android_role.txt" 2>&1 &
    NEARBY_ANDROID_PID=$!
    NEARBY_STATUS=0
    wait "$NEARBY_IOS_PID" || NEARBY_STATUS=1
    wait "$NEARBY_ANDROID_PID" || NEARBY_STATUS=1
    rg -q 'OK \(1 test\)' "$NEARBY_RUN/android-$android_role.txt" || NEARBY_STATUS=1
    # Keep the exact generated manifest with its result instead of deleting evidence.
    mv "$NEARBY_COPY" "$NEARBY_RUN/ios-$role.xctestrun"
    [[ "$NEARBY_STATUS" == 0 ]] || { echo "error: mixed BLE iOS $role failed; $NEARBY_RUN" >&2; exit 1; }
    echo "PASS mixed BLE iOS $role: admission, pointer, exact asset, non-silent native audio"
done
echo "Mixed-platform direct BLE passed; no locked-phone, acoustic, endurance or relay claim"
