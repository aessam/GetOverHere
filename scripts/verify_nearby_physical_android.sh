#!/bin/bash
# One explicit physical BLE guide/guest pair. Uses production admission, codecs and three lanes.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEARBY_ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
NEARBY_JAVA="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
NEARBY_GUIDE="${GOH_NEARBY_GUIDE:?Set GOH_NEARBY_GUIDE to the physical Android serial}"
NEARBY_GUEST="${GOH_NEARBY_GUEST:?Set GOH_NEARBY_GUEST to the other physical Android serial}"
[[ "$NEARBY_GUIDE" != "$NEARBY_GUEST" && "$NEARBY_GUIDE" != emulator-* && "$NEARBY_GUEST" != emulator-* ]] || { echo 'error: two distinct physical phones required' >&2; exit 1; }
[[ -x "$NEARBY_ADB" && -x "$NEARBY_JAVA/bin/java" ]] || { echo 'error: adb/Java unavailable' >&2; exit 1; }
for device in "$NEARBY_GUIDE" "$NEARBY_GUEST"; do
    [[ "$("$NEARBY_ADB" -s "$device" get-state)" == device ]] || { echo "error: unavailable device $device" >&2; exit 1; }
done
NEARBY_RUN="$(mktemp -d /tmp/GetOverHereNearbyPhysical.XXXXXX)"
NEARBY_ROOM="$(uuidgen)"
NEARBY_TRANSPORT="${GOH_NEARBY_TRANSPORT:-bluetooth}"
[[ "$NEARBY_TRANSPORT" == bluetooth || "$NEARBY_TRANSPORT" == aware ]] || { echo 'error: invalid nearby transport' >&2; exit 1; }
NEARBY_DEVICE_PIN="$(jot -r 1 100000 999999)"
echo "Artifacts: $NEARBY_RUN; room: $NEARBY_ROOM"
JAVA_HOME="$NEARBY_JAVA" "$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" :app:assembleDebug :app:assembleDebugAndroidTest
for device in "$NEARBY_GUIDE" "$NEARBY_GUEST"; do
    "$NEARBY_ADB" -s "$device" install -r "$PROJECT_ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
    "$NEARBY_ADB" -s "$device" install -r "$PROJECT_ROOT/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    # Wake the test display only. Never dismiss a secure keyguard or alter credentials.
    "$NEARBY_ADB" -s "$device" shell input keyevent KEYCODE_WAKEUP
done
NEARBY_WIFI_DEVICES=()
NEARBY_WIFI_STATES=()
restore_wifi() {
    local result=$? index device original
    trap - EXIT
    for ((index=0; index<${#NEARBY_WIFI_DEVICES[@]}; index++)); do
        device="${NEARBY_WIFI_DEVICES[$index]}"
        original="${NEARBY_WIFI_STATES[$index]}"
        if [[ "$original" == 1 ]]; then
            "$NEARBY_ADB" -s "$device" shell svc wifi enable || result=1
        else
            "$NEARBY_ADB" -s "$device" shell svc wifi disable || result=1
        fi
        echo "Restored requested Wi-Fi state for $device to $original"
    done
    exit "$result"
}
trap restore_wifi EXIT
if [[ "${GOH_NEARBY_WIFI_OFF:-0}" == 1 ]]; then
    [[ "$NEARBY_TRANSPORT" == bluetooth ]] || { echo 'error: Aware requires Wi-Fi enabled' >&2; exit 1; }
    for device in "$NEARBY_GUIDE" "$NEARBY_GUEST"; do
        original="$("$NEARBY_ADB" -s "$device" shell settings get global wifi_on | tr -d '\r')"
        [[ "$original" == 0 || "$original" == 1 ]] || { echo 'error: unknown original Wi-Fi state' >&2; exit 1; }
        NEARBY_WIFI_DEVICES+=("$device"); NEARBY_WIFI_STATES+=("$original")
        "$NEARBY_ADB" -s "$device" shell svc wifi disable
        [[ "$("$NEARBY_ADB" -s "$device" shell settings get global wifi_on | tr -d '\r')" == 0 ]] || { echo 'error: Wi-Fi did not disable' >&2; exit 1; }
        echo "Wi-Fi disabled for physical BLE test: $device"
    done
fi
run_role() {
    "$NEARBY_ADB" -s "$1" shell am instrument -w -r \
        -e class com.aessam.comeoverhere.NearbyPhysicalTransportTest \
        -e nearbyRole "$2" -e nearbyRoom "$NEARBY_ROOM" \
        -e nearbyTransport "$NEARBY_TRANSPORT" -e nearbyDevicePIN "$NEARBY_DEVICE_PIN" \
        com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner
}
run_role "$NEARBY_GUIDE" guide > "$NEARBY_RUN/guide.txt" 2>&1 &
NEARBY_GUIDE_PID=$!
run_role "$NEARBY_GUEST" guest > "$NEARBY_RUN/guest.txt" 2>&1 &
NEARBY_GUEST_PID=$!
NEARBY_STATUS=0
wait "$NEARBY_GUIDE_PID" || NEARBY_STATUS=1
wait "$NEARBY_GUEST_PID" || NEARBY_STATUS=1
for role in guide guest; do
    if ! rg -q 'OK \(1 test\)' "$NEARBY_RUN/$role.txt"; then NEARBY_STATUS=1; fi
    cat "$NEARBY_RUN/$role.txt"
done
for device in "$NEARBY_GUIDE" "$NEARBY_GUEST"; do
    app_pid="$("$NEARBY_ADB" -s "$device" shell pidof com.aessam.comeoverhere | tr -d '\r')" || app_pid=""
    if [[ "$app_pid" =~ ^[0-9]+$ ]]; then
        "$NEARBY_ADB" -s "$device" logcat -d --pid="$app_pid" -v threadtime > "$NEARBY_RUN/$device-logcat.txt"
    else
        echo "warning: app process unavailable on $device; skipping logcat, never collecting other apps' logs" >&2
    fi
done
[[ "$NEARBY_STATUS" == 0 ]] || { echo "error: physical $NEARBY_TRANSPORT fixture failed; artifacts $NEARBY_RUN" >&2; exit 1; }
echo "Physical Android $NEARBY_TRANSPORT fixture passed (Wi-Fi-off requested: ${GOH_NEARBY_WIFI_OFF:-0}); not microphone, locked-phone, endurance, or relay qualification"
