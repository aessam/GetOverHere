#!/bin/bash
# Slides under speech through both real UIs, Bluetooth only, no instrumentation.
# Guide: iPhone app driven by WebDriverAgent (scripts/ios_drive.py). Guest: Pixel app joined through its
# accessibility tree (scripts/android_ui_join.sh). After IMPORT_AT seconds of speech the guide imports PDF.
# Gates: the guide reports the guest "1 ready" within READY_WITHIN seconds of the import, the guest logs
# no session reconnect and no "Tour asset transfer failed", and guest audio keeps arriving to the end.
# Usage: scripts/verify_real_ui_pdf.sh [PDF=stress-20c] [IMPORT_AT=30] [READY_WITHIN=300] [TAIL=60]
# Needs: scripts/wda.sh running, both apps installed, the PDF in the guide's Files "GetOverHere" folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PDF="${1:-stress-20c}"; IMPORT_AT="${2:-30}"; READY_WITHIN="${3:-300}"; TAIL="${4:-60}"
SERIAL="${ANDROID_SERIAL:-2A111FDH2007A1}"; IOS="${IOS_DEVICE:-00008110-000528410CF8801E}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PY="$ROOT/tools/.venv/bin/python"
OUT="$(mktemp -d /tmp/GetOverHereRealUI-XXXXXX)"
ROOM="Ui-$(uuidgen | tr -d - | tr 'A-F' 'a-f' | cut -c1-8)"
echo "Artifacts: $OUT room=$ROOM"
guest_log() { "$ADB" -s "$SERIAL" logcat -d -v time > "$OUT/logcat.txt"; }
frames() { grep -o 'received [0-9]* audio frames' "$OUT/logcat.txt" | tail -1 | grep -o '[0-9]*' || echo 0; }
guide_ready() { "$PY" "$ROOT/scripts/ios_drive.py" source 2>/dev/null | grep -q 'label="1 ready"'; }

"$ROOT/scripts/wda.sh" status >/dev/null || { echo "error: WebDriverAgent is not running (scripts/wda.sh start)" >&2; exit 1; }
"$PY" "$ROOT/scripts/ios_drive.py" end >/dev/null 2>&1 || true   # a stale tour from an earlier run
"$PY" "$ROOT/scripts/ios_drive.py" create "$ROOM" | tee "$OUT/guide.log"
"$PY" "$ROOT/scripts/ios_drive.py" pointer | tee -a "$OUT/guide.log"
"$ADB" -s "$SERIAL" shell am force-stop com.aessam.comeoverhere
# Slides are cached by SHA-256; a warm cache makes "ready" instant and tests no transfer.
[[ "${KEEP_GUEST_CACHE:-0}" == 1 ]] || "$ADB" -s "$SERIAL" shell run-as com.aessam.comeoverhere rm -rf files/asset-cache files/tour-packs
"$ADB" -s "$SERIAL" logcat -c
"$ROOT/scripts/android_ui_join.sh" "$ROOM" "$SERIAL" "$OUT/guest-joined.png" | tee "$OUT/join.log"

sleep "$IMPORT_AT"
guest_log; before=$(frames)
echo "import $PDF at $(date '+%H:%M:%S'); guest audio frames so far: $before" | tee -a "$OUT/guide.log"
"$PY" "$ROOT/scripts/ios_drive.py" import-pdf "$PDF" | tee -a "$OUT/guide.log"
started=$(date +%s); ready_after=""
while (( $(date +%s) - started < READY_WITHIN )); do
    if guide_ready; then ready_after=$(( $(date +%s) - started )); break; fi
    sleep 10
done
echo "guide reports 1 ready after: ${ready_after:-never (>${READY_WITHIN}s)}" | tee -a "$OUT/guide.log"
"$PY" "$ROOT/scripts/ios_drive.py" shot "$OUT/guide-after-transfer.png" >/dev/null 2>&1 || true
guest_log; mid=$(frames); sleep "$TAIL"; guest_log; after=$(frames)
"$ROOT/scripts/android_ui_join.sh" "$ROOM" "$SERIAL" "$OUT/guest-end.png" >/dev/null 2>&1 || true
"$PY" "$ROOT/scripts/ios_drive.py" end > "$OUT/end.log" 2>&1 || echo "warning: guide end failed; see $OUT/end.log" >&2
xcrun devicectl device copy from --device "$IOS" --domain-type appDataContainer \
    --domain-identifier com.aens.GetOverHere --source Documents/lane-events.log --destination "$OUT/guide-lane-events.log" \
    > "$OUT/copy.log" 2>&1 || echo "warning: no guide lane-events.log; see $OUT/copy.log" >&2

reconnects=$(grep -c 'Session reconnect attempt' "$OUT/logcat.txt" || true)
failures=$(grep -c 'Tour asset transfer failed' "$OUT/logcat.txt" || true)
echo "audioFrames import=$before transferEnd=$mid end=$after reconnects=$reconnects assetFailures=$failures readyAfter=${ready_after:-never}"
[[ -f "$OUT/guide-lane-events.log" ]] && grep -E 'writer failed|bridge failed' "$OUT/guide-lane-events.log" | tail -5 || true
if [[ -n "$ready_after" && "$reconnects" == 0 && "$failures" == 0 && "$after" -gt "$mid" ]]; then
    echo "PASS: real-UI slides under speech; $OUT"
else
    echo "FAIL: real-UI slides under speech; $OUT"; exit 1
fi
