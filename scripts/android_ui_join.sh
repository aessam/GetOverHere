#!/bin/bash
# Join a tour through the real Android UI (no instrumentation, so Compose renders normally).
# Usage: scripts/android_ui_join.sh ROOM_NAME [SERIAL] [SCREENSHOT.png]
set -euo pipefail
ROOM="${1:?room name}"; SERIAL="${2:-2A111FDH2007A1}"; SHOT="${3:-/tmp/GetOverHerePhase5/android-ui-join.png}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP
"$ADB" -s "$SERIAL" shell wm dismiss-keyguard
"$ADB" -s "$SERIAL" shell am start -W -n com.aessam.comeoverhere/.MainActivity >/dev/null

awake() {  # cheap and idempotent: a dozing screen yields an empty accessibility tree
    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP
    "$ADB" -s "$SERIAL" shell wm dismiss-keyguard
}

center_of() {  # prints "x y" of the first accessibility node whose text or content-desc contains $1
    awake
    "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/goh-ui.xml >/dev/null
    "$ADB" -s "$SERIAL" shell cat /sdcard/goh-ui.xml | python3 -c '
import re, sys
needle = sys.argv[1]
for node in re.findall(r"<node [^>]*>", sys.stdin.read()):
    labels = re.findall(r"(?:text|content-desc)=\"([^\"]*)\"", node)
    if any(needle in label for label in labels):
        x1, y1, x2, y2 = map(int, re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", node).groups())
        print((x1 + x2) // 2, (y1 + y2) // 2); break' "$1"
}

for _ in $(seq 1 30); do
    point="$(center_of "$ROOM")"
    [[ -n "$point" ]] && break
    point="$(center_of "Find Nearby Tours")"; [[ -n "$point" ]] && "$ADB" -s "$SERIAL" shell input tap $point
    sleep 3
done
point="$(center_of "$ROOM")"
[[ -n "$point" ]] || { echo "error: room '$ROOM' not shown in the UI" >&2; exit 1; }
"$ADB" -s "$SERIAL" shell input tap $point
for _ in $(seq 1 30); do
    if [[ -n "$(center_of "Leave")" ]]; then
        sleep 3
        awake
        "$ADB" -s "$SERIAL" exec-out screencap -p > "$SHOT"
        echo "joined '$ROOM' in the UI; screenshot $SHOT"
        exit 0
    fi
    sleep 2
done
awake
"$ADB" -s "$SERIAL" exec-out screencap -p > "$SHOT"
echo "error: tour screen (Leave) did not appear; screenshot $SHOT" >&2; exit 1
