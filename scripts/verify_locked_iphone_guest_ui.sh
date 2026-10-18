#!/bin/bash
# Locked iPhone guest through both real UIs, Bluetooth only, no instrumentation (Phase 5 step 5).
# Guide: Pixel app created through its accessibility tree. Guest: iPhone app joined through WebDriverAgent,
# then locked for LOCK_SECONDS. The iPhone's Debug build logs accepted playback bytes every 10 s to
# Documents/lane-events.log (pulled over USB afterwards), so audio is measured while the phone is locked.
# Gates: playback lines keep arriving while locked (largest gap <= 15 s), playback rate >= 90% of the
# 32,000 B/s PCM rate, the iPhone is still LISTENING over Bluetooth after unlock.
# Usage: scripts/verify_locked_iphone_guest_ui.sh [LOCK_SECONDS=600]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_SECONDS="${1:-600}"
SERIAL="${ANDROID_SERIAL:-2A111FDH2007A1}"; IOS="${IOS_DEVICE:-00008110-000528410CF8801E}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PY="$ROOT/tools/.venv/bin/python"
OUT="$(mktemp -d /tmp/GetOverHereLockedUI-XXXXXX)"
ROOM="Lock-$(uuidgen | tr -d - | tr 'A-F' 'a-f' | cut -c1-6)"
echo "Artifacts: $OUT room=$ROOM"

awake() { "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP; "$ADB" -s "$SERIAL" shell wm dismiss-keyguard; }
tree() { awake; "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/goh-ui.xml >/dev/null; "$ADB" -s "$SERIAL" shell cat /sdcard/goh-ui.xml; }
tap() {  # tap the first node whose text or content-desc contains $1
    local point
    point="$(tree | python3 -c '
import re, sys
needle = sys.argv[1]
for node in re.findall(r"<node [^>]*>", sys.stdin.read()):
    if any(needle in label for label in re.findall(r"(?:text|content-desc)=\"([^\"]*)\"", node)):
        a = list(map(int, re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node).groups()))
        print((a[0] + a[2]) // 2, (a[1] + a[3]) // 2); break' "$1")"
    [[ -n "$point" ]] || { echo "error: '$1' not on the Pixel screen" >&2; return 1; }
    "$ADB" -s "$SERIAL" shell input tap $point
}
texts() { tree | grep -o -E 'text="[^"]+"' | sed 's/text=//' | tr '\n' ' '; }

"$ROOT/scripts/wda.sh" status >/dev/null || { echo "error: WebDriverAgent is not running (scripts/wda.sh start)" >&2; exit 1; }
"$PY" "$ROOT/scripts/ios_drive.py" leave >/dev/null 2>&1 || true
"$PY" "$ROOT/scripts/ios_drive.py" end >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" shell am force-stop com.aessam.comeoverhere
"$ADB" -s "$SERIAL" logcat -c
awake
"$ADB" -s "$SERIAL" shell am start -W -n com.aessam.comeoverhere/.MainActivity >/dev/null
sleep 2
tap "Create Channel"; sleep 1
tap "Channel name"; "$ADB" -s "$SERIAL" shell input text "$ROOM"; sleep 1
tap "Create"; sleep 5
echo "guide: $(texts)" | tee "$OUT/guide-created.txt"

"$PY" "$ROOT/scripts/ios_drive.py" join "$ROOM" | tee "$OUT/join.log"
sleep 20
"$PY" "$ROOT/scripts/ios_drive.py" source > "$OUT/ios-before-lock.xml"
grep -q 'LISTENING' "$OUT/ios-before-lock.xml" || { echo "error: iPhone guest is not LISTENING after join" >&2; exit 1; }

lock_at=$(date -u +%H:%M:%S)
"$PY" "$ROOT/scripts/ios_drive.py" lock | tee -a "$OUT/join.log"
for (( t = 30; t <= LOCK_SECONDS; t += 30 )); do
    sleep 30
    echo "t=${t}s guide: $(texts)" >> "$OUT/guide-while-locked.txt"
done
unlock_at=$(date -u +%H:%M:%S)
"$PY" "$ROOT/scripts/ios_drive.py" unlock | tee -a "$OUT/join.log"
sleep 5
"$PY" "$ROOT/scripts/ios_drive.py" source > "$OUT/ios-after-unlock.xml"
"$PY" "$ROOT/scripts/ios_drive.py" shot "$OUT/ios-after-unlock.png" >/dev/null 2>&1 || true
awake; "$ADB" -s "$SERIAL" exec-out screencap -p > "$OUT/guide-end.png"
"$ADB" -s "$SERIAL" logcat -d -v time > "$OUT/guide-logcat.txt"
xcrun devicectl device copy from --device "$IOS" --domain-type appDataContainer --domain-identifier com.aens.GetOverHere \
    --source Documents/lane-events.log --destination "$OUT/ios-lane-events.log" > "$OUT/copy.log" 2>&1
"$PY" "$ROOT/scripts/ios_drive.py" leave > "$OUT/leave.log" 2>&1 || true
tap "End" > /dev/null 2>&1 || true

python3 - "$OUT" "$lock_at" "$unlock_at" <<'EOF'
import json, re, sys
from pathlib import Path
out, lock_at, unlock_at = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
def seconds(stamp):
    h, m, s = stamp.split(":"); return int(h) * 3600 + int(m) * 60 + float(s)
lo, hi = seconds(lock_at), seconds(unlock_at)
points = []
for line in (out / "ios-lane-events.log").read_text().splitlines():
    match = re.match(r"(\d\d:\d\d:\d\d(?:\.\d+)?)\S* guest playback bytes=(\d+)", line)
    if match and lo <= seconds(match.group(1)) <= hi:
        points.append((seconds(match.group(1)), int(match.group(2))))
after = (out / "ios-after-unlock.xml").read_text()
summary = {"lockSeconds": round(hi - lo), "playbackLines": len(points)}
if len(points) >= 2:
    gaps = [b[0] - a[0] for a, b in zip(points, points[1:])]
    rate = (points[-1][1] - points[0][1]) / (points[-1][0] - points[0][0])
    summary.update(maxGapSeconds=round(max(gaps), 1), bytesPerSecond=round(rate), pcmRatio=round(rate / 32000, 3),
                   coveredSeconds=round(points[-1][0] - points[0][0]))
summary["listeningAfterUnlock"] = "LISTENING" in after
summary["bluetoothAfterUnlock"] = "Bluetooth" in after
(out / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary))
ok = (len(points) >= 2 and summary["maxGapSeconds"] <= 15 and summary["pcmRatio"] >= 0.9
      and summary["coveredSeconds"] >= (hi - lo) - 20 and summary["listeningAfterUnlock"])
print(("PASS" if ok else "FAIL") + f": locked iPhone guest; {out}")
sys.exit(0 if ok else 1)
EOF
