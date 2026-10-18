#!/bin/bash
# Prepare a tour on the Android guide through its real UI (ADR-080): Tours > New Tour NAME > Add PDF, then
# export it with Share and copy the .gohtour to OUT on the Mac. The PDF is pushed to Download first.
# Usage: scripts/android_prepare_tour.sh NAME LOCAL_PDF OUT.gohtour [SERIAL]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?tour name}"; PDF="${2:?local pdf}"; OUT="${3:?output .gohtour}"; SERIAL="${4:-2A111FDH2007A1}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PKG=com.aessam.comeoverhere

tree() {
    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP
    "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/goh-ui.xml >/dev/null
    "$ADB" -s "$SERIAL" shell cat /sdcard/goh-ui.xml
}
tap() {  # tap $1 (exact label first), waiting up to $2 seconds for it to appear
    local point="" deadline=$(( $(date +%s) + ${2:-15} ))
    while [[ -z "$point" ]] && (( $(date +%s) < deadline )); do
        point="$(tree | "$ROOT/scripts/android_tree.py" "$1")"
        [[ -n "$point" ]] || sleep 1
    done
    [[ -n "$point" ]] || { echo "error: '$1' not on the Pixel screen" >&2; exit 1; }
    "$ADB" -s "$SERIAL" shell input tap $point
}

PDF_NAME="$(basename "$PDF")"
"$ADB" -s "$SERIAL" push "$PDF" "/sdcard/Download/$PDF_NAME" >/dev/null
"$ADB" -s "$SERIAL" shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///sdcard/Download/$PDF_NAME" >/dev/null
"$ADB" -s "$SERIAL" shell am start -W -n "$PKG/.MainActivity" >/dev/null
tap "Tours"
if ! tree | grep -q "text=\"$NAME\""; then
    tap "New Tour"
    tap "Tour name"
    "$ADB" -s "$SERIAL" shell input text "$(printf '%s' "$NAME" | sed 's/ /%s/g')"
    tap "Create"
fi
tap "Add PDF"
tap "${PDF_NAME%.pdf}" 20     # DocumentsUI lists the freshly scanned download under Recent
deadline=$(( $(date +%s) + 120 ))
until tree | grep -q -E 'text="[1-9][0-9]* slides'; do
    (( $(date +%s) < deadline )) || { echo "error: slides were not added" >&2; exit 1; }
    sleep 2
done
tap "Share"
sleep 3
"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_BACK   # close the chooser; the export is already written
# Export folders are UUIDs (no spaces); the file name may contain spaces, so it stays inside one quoted shell.
latest="$("$ADB" -s "$SERIAL" shell run-as "$PKG" ls -t cache/shared-tours | head -1 | tr -d '\r')"
[[ -n "$latest" ]] || { echo "error: no exported .gohtour in the app cache" >&2; exit 1; }
"$ADB" -s "$SERIAL" exec-out "run-as $PKG sh -c 'cat cache/shared-tours/$latest/*.gohtour'" > "$OUT"
[[ -s "$OUT" ]] || { echo "error: copied an empty pack from cache/shared-tours/$latest" >&2; exit 1; }
echo "prepared '$NAME' and exported $(wc -c < "$OUT" | tr -d ' ') bytes to $OUT"
