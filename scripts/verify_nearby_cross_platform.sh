#!/bin/bash
# One connected iPhone and one physical Android; both guide directions by default.
# No LAN connector is available to either test fixture. Does not alter radio settings.
set -euo pipefail
NEARBY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEARBY_IOS="${GOH_IOS_DEVICE:?Set GOH_IOS_DEVICE to the connected unlocked iPhone UDID}"
NEARBY_ANDROID="${GOH_NEARBY_ANDROID:?Set GOH_NEARBY_ANDROID to the physical Android serial}"
NEARBY_ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
NEARBY_JAVA="${GOH_ANDROID_JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
NEARBY_PREBUILT="${GOH_NEARBY_USE_BUILT:-0}"
NEARBY_PROFILE="${GOH_NEARBY_PROFILE:-protocol}"
NEARBY_ROLE_SELECTION="${GOH_NEARBY_IOS_ROLES:-both}"
NEARBY_PROBE_STYLE="${GOH_BLE_PROBE_STYLE:-queued}"
[[ "$NEARBY_PREBUILT" == 0 || "$NEARBY_PREBUILT" == 1 ]] || { echo 'error: GOH_NEARBY_USE_BUILT must be 0 or 1' >&2; exit 1; }
[[ "$NEARBY_PROFILE" == protocol || "$NEARBY_PROFILE" == live || "$NEARBY_PROFILE" == channel-probe ]] || { echo 'error: GOH_NEARBY_PROFILE must be protocol, live or channel-probe' >&2; exit 1; }
case "$NEARBY_ROLE_SELECTION" in
    both) NEARBY_ROLES=(guide guest) ;;
    guide|guest) NEARBY_ROLES=("$NEARBY_ROLE_SELECTION") ;;
    *) echo 'error: GOH_NEARBY_IOS_ROLES must be both, guide or guest' >&2; exit 1 ;;
esac
if [[ "$NEARBY_PROFILE" == channel-probe ]]; then
    [[ "$NEARBY_ROLE_SELECTION" == guest ]] || { echo 'error: channel-probe requires GOH_NEARBY_IOS_ROLES=guest' >&2; exit 1; }
    case "$NEARBY_PROBE_STYLE" in
        queued|sequential|after_close|distinct_psms) ;;
        *) echo 'error: GOH_BLE_PROBE_STYLE must be queued, sequential, after_close or distinct_psms' >&2; exit 1 ;;
    esac
fi
export DEVELOPER_DIR="${GOH_XCODE_DEVELOPER_DIR:-$(xcode-select -p)}"
NEARBY_RUN="$(mktemp -d /tmp/GetOverHereNearbyCross.XXXXXX)"
echo "Artifacts: $NEARBY_RUN"
NEARBY_IOS_PID= NEARBY_ANDROID_PID= NEARBY_LOG_PID= NEARBY_BUILD_PID= NEARBY_COPY=
is_owned_running_job() {
    local job
    for job in $(jobs -pr); do [[ "$job" != "$1" ]] || return 0; done
    return 1
}
cleanup() {
    local status=$? pid deadline
    trap - EXIT INT TERM
    # Only jobs launched by this script; no killall, device force-stop or log reset.
    for pid in "$NEARBY_IOS_PID" "$NEARBY_ANDROID_PID" "$NEARBY_LOG_PID" "$NEARBY_BUILD_PID"; do
        if [[ -n "$pid" ]] && is_owned_running_job "$pid"; then kill -TERM "$pid" 2>/dev/null || true; fi
    done
    deadline=$((SECONDS + 5))
    for pid in "$NEARBY_IOS_PID" "$NEARBY_ANDROID_PID" "$NEARBY_LOG_PID" "$NEARBY_BUILD_PID"; do
        [[ -n "$pid" ]] || continue
        while is_owned_running_job "$pid" && (( SECONDS < deadline )); do sleep 0.1; done
        if is_owned_running_job "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
        wait "$pid" 2>/dev/null || true
    done
    if [[ -n "$NEARBY_COPY" && -f "$NEARBY_COPY" ]]; then
        mv "$NEARBY_COPY" "$NEARBY_RUN/interrupted.xctestrun"
    fi
    echo "exit_status=$status" >> "$NEARBY_RUN/run.txt"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -d "$DEVELOPER_DIR" && "$NEARBY_ANDROID" != emulator-* && -x "$NEARBY_ADB" ]] || { echo 'error: invalid physical device/toolchain' >&2; exit 1; }
[[ "$NEARBY_PREBUILT" == 1 || -x "$NEARBY_JAVA/bin/java" ]] || { echo 'error: Android Java toolchain unavailable' >&2; exit 1; }
xcodebuild -version > "$NEARBY_RUN/xcode.txt" 2>&1 || { echo 'error: selected Xcode is unavailable' >&2; exit 1; }
xcrun --find devicectl > "$NEARBY_RUN/devicectl.txt" 2>&1 || { echo 'error: selected Xcode has no devicectl' >&2; exit 1; }
[[ "$("$NEARBY_ADB" -s "$NEARBY_ANDROID" get-state)" == device ]] || { echo 'error: Android unavailable' >&2; exit 1; }
{
    echo "started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "developer_dir=$DEVELOPER_DIR"
    echo "ios_device=$NEARBY_IOS"
    echo "android_serial=$NEARBY_ANDROID"
    echo "workspace_head=$(git -C "$NEARBY_ROOT" rev-parse HEAD)"
    echo "prebuilt=$NEARBY_PREBUILT"
    echo "profile=$NEARBY_PROFILE"
    echo "ios_roles=$NEARBY_ROLE_SELECTION"
    if [[ "$NEARBY_PROFILE" == channel-probe ]]; then echo "probe_style=$NEARBY_PROBE_STYLE"; fi
    if [[ "$NEARBY_PREBUILT" == 1 ]]; then echo 'source_provenance=prebuilt; no correspondence to workspace HEAD claimed';
    else echo 'source_provenance=built from working tree; see workspace-status.txt and artifact hashes'; fi
} > "$NEARBY_RUN/run.txt"
git -C "$NEARBY_ROOT" status --short > "$NEARBY_RUN/workspace-status.txt"
xcrun devicectl device info details --device "$NEARBY_IOS" --timeout 20 > "$NEARBY_RUN/ios-device.txt" 2>&1 || {
    echo "error: iPhone developer connection unavailable; $NEARBY_RUN/ios-device.txt" >&2; exit 1;
}
xcrun devicectl device info lockState --device "$NEARBY_IOS" --timeout 20 --json-output "$NEARBY_RUN/lock.json" > "$NEARBY_RUN/lock.txt" 2>&1 || {
    echo "error: iPhone developer connection unavailable; $NEARBY_RUN/lock.txt" >&2; exit 1;
}
if rg -q '"passcodeRequired"\s*:\s*true' "$NEARBY_RUN/lock.json"; then
    echo 'error: iPhone must be unlocked for test installation' >&2; exit 1
fi
NEARBY_DERIVED="${GOH_IOS_NEARBY_DERIVED:-/tmp/GetOverHereNearbySigned}"
NEARBY_APP_APK="$NEARBY_ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
NEARBY_TEST_APK="$NEARBY_ROOT/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
if [[ "$NEARBY_PREBUILT" == 0 ]]; then
xcodebuild -quiet -project "$NEARBY_ROOT/iOS/GetOverHere.xcodeproj" -scheme GetOverHere \
    -destination "platform=iOS,id=$NEARBY_IOS" -derivedDataPath "$NEARBY_DERIVED" \
    -parallel-testing-enabled NO -collect-test-diagnostics never build-for-testing > "$NEARBY_RUN/build-ios.txt" 2>&1 &
NEARBY_BUILD_PID=$!
NEARBY_BUILD_STATUS=0
wait "$NEARBY_BUILD_PID" || NEARBY_BUILD_STATUS=$?
NEARBY_BUILD_PID=
[[ "$NEARBY_BUILD_STATUS" == 0 ]] || {
    echo "error: signed iOS test build failed; $NEARBY_RUN/build-ios.txt" >&2; exit 1;
}
JAVA_HOME="$NEARBY_JAVA" "$NEARBY_ROOT/Android/gradlew" -p "$NEARBY_ROOT/Android" \
    :app:assembleDebug :app:assembleDebugAndroidTest > "$NEARBY_RUN/build-android.txt" 2>&1 &
NEARBY_BUILD_PID=$!
NEARBY_BUILD_STATUS=0
wait "$NEARBY_BUILD_PID" || NEARBY_BUILD_STATUS=$?
NEARBY_BUILD_PID=
[[ "$NEARBY_BUILD_STATUS" == 0 ]] || { echo "error: Android build failed; $NEARBY_RUN/build-android.txt" >&2; exit 1; }
fi
NEARBY_MANIFESTS=("$NEARBY_DERIVED"/Build/Products/GetOverHere_GetOverHere_iphoneos*.xctestrun)
[[ ${#NEARBY_MANIFESTS[@]} == 1 && -f "${NEARBY_MANIFESTS[0]}" ]] || { echo 'error: expected one device test manifest' >&2; exit 1; }
[[ -f "$NEARBY_APP_APK" && -f "$NEARBY_TEST_APK" && -f "$NEARBY_DERIVED/Build/Products/Debug-iphoneos/GetOverHere.app/GetOverHere" ]] || { echo 'error: missing built app/test artifacts' >&2; exit 1; }
shasum -a 256 "${NEARBY_MANIFESTS[0]}" "$NEARBY_APP_APK" "$NEARBY_TEST_APK" > "$NEARBY_RUN/artifacts.sha256"
while IFS= read -r binary; do shasum -a 256 "$binary" >> "$NEARBY_RUN/artifacts.sha256"; done < <(
    rg --files --hidden "$NEARBY_DERIVED/Build/Products/Debug-iphoneos" | rg '/(GetOverHere|GetOverHereTests|GetOverHereUITests)(\.debug\.dylib)?$'
)
"$NEARBY_ADB" -s "$NEARBY_ANDROID" install -r "$NEARBY_APP_APK" > "$NEARBY_RUN/install-app.txt" 2>&1
"$NEARBY_ADB" -s "$NEARBY_ANDROID" install -r "$NEARBY_TEST_APK" > "$NEARBY_RUN/install-test.txt" 2>&1
NEARBY_UID="$("$NEARBY_ADB" -s "$NEARBY_ANDROID" shell cmd package list packages -U com.aessam.comeoverhere | tr -d '\r' | sed -n 's/^package:com\.aessam\.comeoverhere uid:\([0-9][0-9]*\)$/\1/p')"
[[ "$NEARBY_UID" =~ ^[0-9]+$ ]] || { echo 'error: cannot resolve unique Android app UID for scoped logs' >&2; exit 1; }
"$NEARBY_ADB" -s "$NEARBY_ANDROID" logcat --uid="$NEARBY_UID" -T 1 -v threadtime > "$NEARBY_RUN/android-app-logcat.txt" 2>&1 &
NEARBY_LOG_PID=$!
echo 'Both fixtures start concurrently; discovery timeout includes platform test-runner startup skew.' >> "$NEARBY_RUN/run.txt"
for role in "${NEARBY_ROLES[@]}"; do
    NEARBY_ROOM="$(uuidgen)"
    NEARBY_ROOM_NAME="Physical-tour-$NEARBY_ROOM"
    NEARBY_TEMP="$(mktemp "$NEARBY_DERIVED/Build/Products/nearby-cross.XXXXXX")"
    NEARBY_COPY="$NEARBY_TEMP.xctestrun"
    mv "$NEARBY_TEMP" "$NEARBY_COPY"
    cp "${NEARBY_MANIFESTS[0]}" "$NEARBY_COPY"
    # Generated manifests only: preserve relative __TESTROOT__ paths.
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:BlueprintName' "$NEARBY_COPY")" == GetOverHereTests ]] || { echo 'error: unexpected iOS test target' >&2; exit 1; }
    if [[ "$NEARBY_PROFILE" == live ]]; then
        plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_NEARBY_LIVE_ROOM_NAME -string "$NEARBY_ROOM_NAME" "$NEARBY_COPY"
        NEARBY_IOS_TEST=NearbyLiveSessionTests
        NEARBY_ANDROID_TEST=NearbyLiveSessionTest
        NEARBY_ANDROID_ROOM_ARG=nearbyRoomName
        NEARBY_ANDROID_ROOM_VALUE="$NEARBY_ROOM_NAME"
    else
        plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_NEARBY_ROOM -string "$NEARBY_ROOM" "$NEARBY_COPY"
        NEARBY_IOS_TEST=NearbyPhysicalTransportTests
        NEARBY_ANDROID_TEST=NearbyPhysicalTransportTest
        NEARBY_ANDROID_ROOM_ARG=nearbyRoom
        NEARBY_ANDROID_ROOM_VALUE="$NEARBY_ROOM"
        if [[ "$NEARBY_PROFILE" == channel-probe ]]; then
            plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_BLE_PROBE_STYLE -string "$NEARBY_PROBE_STYLE" "$NEARBY_COPY"
            NEARBY_IOS_TEST=BluetoothChannelProbeTests
            NEARBY_ANDROID_TEST=BluetoothChannelProbeTest
        fi
    fi
    plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables.GOH_NEARBY_ROLE -string "$role" "$NEARBY_COPY"
    android_role=guide
    [[ "$role" == guide ]] && android_role=guest
    NEARBY_ANDROID_TEST_ARGS=(-e class "com.aessam.comeoverhere.$NEARBY_ANDROID_TEST"
        -e nearbyRole "$android_role" -e "$NEARBY_ANDROID_ROOM_ARG" "$NEARBY_ANDROID_ROOM_VALUE")
    if [[ "$NEARBY_PROFILE" == channel-probe ]]; then
        NEARBY_ANDROID_TEST_ARGS+=(-e nearbyProbeStyle "$NEARBY_PROBE_STYLE")
    fi
    echo "ios_${role}_launch_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$NEARBY_RUN/run.txt"
    xcodebuild -quiet -xctestrun "$NEARBY_COPY" -destination "platform=iOS,id=$NEARBY_IOS" \
        -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$NEARBY_RUN/ios-$role.xcresult" \
        test-without-building "-only-testing:GetOverHereTests/$NEARBY_IOS_TEST" \
        > "$NEARBY_RUN/ios-$role.txt" 2>&1 &
    NEARBY_IOS_PID=$!
    echo "android_${android_role}_launch_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$NEARBY_RUN/run.txt"
    "$NEARBY_ADB" -s "$NEARBY_ANDROID" shell am instrument -w -r \
        "${NEARBY_ANDROID_TEST_ARGS[@]}" \
        com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner \
        > "$NEARBY_RUN/android-$android_role.txt" 2>&1 &
    NEARBY_ANDROID_PID=$!
    NEARBY_STATUS=0
    NEARBY_DEADLINE=$((SECONDS + 240))
    while [[ -n "$NEARBY_IOS_PID" || -n "$NEARBY_ANDROID_PID" ]]; do
        if [[ -n "$NEARBY_IOS_PID" ]] && ! kill -0 "$NEARBY_IOS_PID" 2>/dev/null; then
            wait "$NEARBY_IOS_PID" || NEARBY_STATUS=1
            NEARBY_IOS_PID=
        fi
        if [[ -n "$NEARBY_ANDROID_PID" ]] && ! kill -0 "$NEARBY_ANDROID_PID" 2>/dev/null; then
            wait "$NEARBY_ANDROID_PID" || NEARBY_STATUS=1
            NEARBY_ANDROID_PID=
        fi
        [[ "$NEARBY_STATUS" == 0 ]] || break
        if (( SECONDS >= NEARBY_DEADLINE )); then
            echo 'error: paired test exceeded 240 second deadline' >&2
            NEARBY_STATUS=1
            break
        fi
        [[ -z "$NEARBY_IOS_PID" && -z "$NEARBY_ANDROID_PID" ]] || sleep 0.2
    done
    rg -q 'OK \(1 test\)' "$NEARBY_RUN/android-$android_role.txt" || NEARBY_STATUS=1
    if rg -q 'INSTRUMENTATION_STATUS_CODE: -[1-4]|INSTRUMENTATION_FAILED' "$NEARBY_RUN/android-$android_role.txt"; then
        echo 'error: Android test failed, was ignored or skipped' >&2
        NEARBY_STATUS=1
    fi
    if [[ -d "$NEARBY_RUN/ios-$role.xcresult" ]]; then
        xcrun xcresulttool get test-results summary --path "$NEARBY_RUN/ios-$role.xcresult" \
            > "$NEARBY_RUN/ios-$role-summary.json" 2> "$NEARBY_RUN/ios-$role-summary-error.txt" || NEARBY_STATUS=1
        for field in totalTestCount passedTests; do
            [[ "$(plutil -extract "$field" raw -o - "$NEARBY_RUN/ios-$role-summary.json")" == 1 ]] || NEARBY_STATUS=1
        done
        for field in failedTests skippedTests expectedFailures; do
            [[ "$(plutil -extract "$field" raw -o - "$NEARBY_RUN/ios-$role-summary.json")" == 0 ]] || NEARBY_STATUS=1
        done
    else
        NEARBY_STATUS=1
    fi
    kill -0 "$NEARBY_LOG_PID" 2>/dev/null || { echo 'error: app-scoped Android log capture stopped' >&2; NEARBY_STATUS=1; }
    # Keep the exact generated manifest with its result instead of deleting evidence.
    mv "$NEARBY_COPY" "$NEARBY_RUN/ios-$role.xctestrun"
    NEARBY_COPY=
    if [[ "$NEARBY_STATUS" != 0 ]]; then
        if [[ -d "$NEARBY_RUN/ios-$role.xcresult" ]]; then
            # Export only diagnostics already in the result bundle. Never request a sysdiagnose.
            xcrun xcresulttool export diagnostics --path "$NEARBY_RUN/ios-$role.xcresult" \
                --output-path "$NEARBY_RUN/ios-$role-diagnostics" \
                > "$NEARBY_RUN/ios-$role-diagnostics-export.txt" 2>&1 || {
                echo "warning: saved xcresult diagnostics unavailable; $NEARBY_RUN/ios-$role-diagnostics-export.txt" >&2
            }
        fi
        echo "error: mixed BLE $NEARBY_PROFILE iOS $role failed; $NEARBY_RUN" >&2
        exit 1
    fi
    if [[ "$NEARBY_PROFILE" == live ]]; then
        echo "PASS mixed BLE iOS $role: production admission, microphone/playback readiness and pointer; not acoustic qualification"
    elif [[ "$NEARBY_PROFILE" == channel-probe ]]; then
        echo "PASS native Bluetooth channel-open probe: iOS guest, Android guide, style=$NEARBY_PROBE_STYLE; no admission or live-audio claim"
    else
        echo "PASS mixed BLE iOS $role: admission, pointer, exact asset, non-silent native audio"
    fi
done
if [[ "$NEARBY_PROFILE" == channel-probe ]]; then
    echo "Native channel-open probe passed: iOS guest, Android guide, style=$NEARBY_PROBE_STYLE only; no application audio qualification"
else
    echo "Mixed-platform direct BLE $NEARBY_PROFILE passed for iOS roles: ${NEARBY_ROLES[*]}; Android used the opposite role; no locked-phone, acoustic, endurance or relay claim"
fi
