#!/bin/bash
# Targeted mutations: a Bluetooth-only guest must never admit over, or count as joinable through, an advertised LAN host.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
CLASS='com.aessam.comeoverhere.ChannelServiceLifecycleTest'
SOURCE='app/src/main/java/com/aessam/comeoverhere/service/ChannelService.kt'
REPORT_PATH='app/build/test-results/testDebugUnitTest/TEST-com.aessam.comeoverhere.ChannelServiceLifecycleTest.xml'
for tool in rsync perl rg python3; do command -v "$tool" >/dev/null; done
test -x "$JAVA_HOME/bin/java"
test -x "$PROJECT_ROOT/Android/gradlew"
test "$(rg -c -F 'channel.audioHostIP.takeIf { lanRoutePermitted }' "$PROJECT_ROOT/Android/$SOURCE")" = 1
test "$(rg -c -F '(channel.audioHostIP != null && lanRoutePermitted) || channel.createdBy == localPeerID' "$PROJECT_ROOT/Android/$SOURCE")" = 1

echo '[1/4] Baseline route-policy regressions'
"$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" :app:testDebugUnitTest --tests "$CLASS.bluetoothOnly*" --rerun-tasks

SCRATCH="$(mktemp -d /tmp/goh-route-mutation.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
rsync -a --exclude build --exclude .gradle --exclude .kotlin "$PROJECT_ROOT/Android/" "$SCRATCH/"
cp "$SCRATCH/$SOURCE" "$SCRATCH/original.kt"

# kill <name> <test method> <perl substitution>: the mutant must compile and fail that test with an assertion.
kill_mutant() {
    local name="$1" method="$2" substitution="$3"
    cp "$SCRATCH/original.kt" "$SCRATCH/$SOURCE"
    perl -0pi -e "$substitution" "$SCRATCH/$SOURCE"
    if cmp -s "$SCRATCH/original.kt" "$SCRATCH/$SOURCE"; then echo "FAIL: $name substitution did not apply" >&2; exit 1; fi
    rm -f "$SCRATCH/$REPORT_PATH"
    if "$SCRATCH/gradlew" -p "$SCRATCH" :app:testDebugUnitTest --tests "$CLASS.$method" > "$SCRATCH/$name.log" 2>&1; then
        cat "$SCRATCH/$name.log"; echo "FAIL: $name survived" >&2; exit 1
    fi
    if ! test -f "$SCRATCH/$REPORT_PATH"; then
        tail -40 "$SCRATCH/$name.log"; echo "FAIL: $name produced no test report (compile failure is not a kill)" >&2; exit 1
    fi
    python3 - "$SCRATCH/$REPORT_PATH" "$method" "$name" <<'PY'
import sys, xml.etree.ElementTree as ET
report, method, name = sys.argv[1:]
case = next((c for c in ET.parse(report).getroot().iter("testcase") if c.get("name") == method), None)
failure = None if case is None else case.find("failure")
if failure is None or "AssertionError" not in (failure.get("type") or ""):
    sys.exit(f"FAIL: {name} did not fail {method} with an assertion")
print(f"{name}: killed by {method}: {(failure.get('message') or '').splitlines()[0][:160]}")
PY
}

echo '[2/4] Join admits over the advertised LAN host despite Bluetooth-only'
kill_mutant lan-admission bluetoothOnlyNeverAdmitsOrReconnectsOverAdvertisedLAN \
    's/channel\.audioHostIP\.takeIf \{ lanRoutePermitted \}/channel.audioHostIP/'
echo '[3/4] LAN-only room reported joinable despite Bluetooth-only'
kill_mutant lan-joinable bluetoothOnlyCannotJoinLANOnlyOrAwareRooms \
    's/\(channel\.audioHostIP != null && lanRoutePermitted\) \|\| channel\.createdBy/channel.audioHostIP != null || channel.createdBy/'
echo '[4/4] PASS: baseline passed; 2/2 route-policy mutants killed by assertions'
