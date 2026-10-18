#!/bin/bash
# Real-UI slides-under-speech run: iPhone guide driven through WebDriverAgent, Pixel guest through the
# NearbyLiveSessionTest UI path, Bluetooth only. The guide imports a PDF after IMPORT_AT seconds of speech.
# Gates: guest instrumentation OK, no stalled windows, no "Tour asset transfer failed" on the guest.
# Usage: scripts/verify_real_ui_pdf.sh [PDF_NAME=stress-20c] [HOLD_SECONDS=420] [IMPORT_AT=60]
# Needs: scripts/wda.sh running, both apps installed, the PDF in the guide's Files "GetOverHere" folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PDF="${1:-stress-20c}"; HOLD="${2:-420}"; IMPORT_AT="${3:-60}"
SERIAL="${ANDROID_SERIAL:-2A111FDH2007A1}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PY="$ROOT/tools/.venv/bin/python"
OUT="$(mktemp -d /tmp/GetOverHereRealUI-XXXXXX)"
ROOM="Ui-$(uuidgen | tr -d - | tr 'A-F' 'a-f' | cut -c1-8)"
echo "Artifacts: $OUT room=$ROOM"

"$ROOT/scripts/wda.sh" status >/dev/null || { echo "error: WebDriverAgent is not running (scripts/wda.sh start)" >&2; exit 1; }
"$PY" "$ROOT/scripts/ios_drive.py" end >/dev/null 2>&1 || true   # a stale tour from an earlier run
"$PY" "$ROOT/scripts/ios_drive.py" create "$ROOM" | tee "$OUT/create.log"
"$PY" "$ROOT/scripts/ios_drive.py" pointer | tee -a "$OUT/create.log"   # the guest test waits for authoritative pointer state

"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP
"$ADB" -s "$SERIAL" shell wm dismiss-keyguard
"$ADB" -s "$SERIAL" logcat -c
"$ADB" -s "$SERIAL" shell am instrument -w -r -e class com.aessam.comeoverhere.NearbyLiveSessionTest \
    -e nearbyRole guest -e nearbyUI true -e nearbyRoomName "$ROOM" -e nearbyHoldSeconds "$HOLD" \
    com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner > "$OUT/android.log" 2>&1 &
GUEST=$!

until "$ADB" -s "$SERIAL" logcat -d -s NearbyLive:I | grep -q "Endurance t=${IMPORT_AT}s"; do
    kill -0 "$GUEST" 2>/dev/null || { echo "error: guest ended before t=${IMPORT_AT}s; see $OUT/android.log" >&2; exit 1; }
    sleep 2
done
echo "import $PDF at $(date '+%H:%M:%S')"
"$PY" "$ROOT/scripts/ios_drive.py" import-pdf "$PDF" | tee "$OUT/import.log"

wait "$GUEST" || true
"$ADB" -s "$SERIAL" logcat -d -v time > "$OUT/logcat.txt"
"$PY" "$ROOT/scripts/ios_drive.py" end > "$OUT/end.log" 2>&1 || echo "warning: guide end failed; see $OUT/end.log" >&2
# Guide-side lane removals and bridge endings (Debug builds; GuideLaneEvents), pulled over USB.
xcrun devicectl device copy from --device "${IOS_DEVICE:-00008110-000528410CF8801E}" --domain-type appDataContainer \
    --domain-identifier com.aens.GetOverHere --source Documents/lane-events.log --destination "$OUT/guide-lane-events.log" \
    > "$OUT/copy.log" 2>&1 && grep -E 'removed|bridge failed' "$OUT/guide-lane-events.log" | tail -20 \
    || echo "warning: no guide lane-events.log; see $OUT/copy.log" >&2

grep -E 'NearbyLive.*Endurance (t=|summary)' "$OUT/logcat.txt" \
    | sed -E 's/.*Endurance (t=[0-9]+s) delta=(-?[0-9]+).*realtimeFromRadio=([0-9]+).*reliableFromRadio=([0-9]+)\}.*/\1 pcm=\2 audioDown=\3 assetDown=\4/' \
    | tee "$OUT/windows.txt"
failures=$(grep -c 'Tour asset transfer failed' "$OUT/logcat.txt" || true)
late=$(grep -c 'no longer in flight' "$OUT/logcat.txt" || true)
echo "assetFailures=$failures lateChunks=$late"
if grep -q 'OK (1 test)' "$OUT/android.log" && grep -q 'stalledWindowsAt=\[\]' "$OUT/logcat.txt" && [[ "$failures" == 0 ]]; then
    echo "PASS: real-UI slides under speech; $OUT"
else
    echo "FAIL: real-UI slides under speech; $OUT"; exit 1
fi
