#!/bin/bash
# One targeted mutation: encoder retirement must not reset guest playout sequence.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
TEST='com.aessam.comeoverhere.RealtimeCaptureInboxTest.replacementContinuesAuthenticatedGuestPlayoutWithoutResettingTimeline'
SOURCE='app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt'
for tool in rsync perl rg; do command -v "$tool" >/dev/null; done
test -x "$JAVA_HOME/bin/java"
test -x "$PROJECT_ROOT/Android/gradlew"
test "$(rg -c 'codecStates.remove\(codec\)' "$PROJECT_ROOT/Android/$SOURCE")" = 1
echo '[1/3] Baseline regression'
"$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" :app:testDebugUnitTest --tests "$TEST" --rerun-tasks
SCRATCH="$(mktemp -d /tmp/goh-audio-mutation.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
rsync -a --exclude build --exclude .gradle --exclude .kotlin "$PROJECT_ROOT/Android/" "$SCRATCH/"
echo '[2/3] Reset the sequence on retirement in an isolated source copy'
perl -0pi -e 's/codecStates\.remove\(codec\)/nextSequences.remove(codec)\n            codecStates.remove(codec)/' "$SCRATCH/$SOURCE"
if "$SCRATCH/gradlew" -p "$SCRATCH" :app:testDebugUnitTest --tests "$TEST" > "$SCRATCH/mutant.log" 2>&1; then
    cat "$SCRATCH/mutant.log"
    echo 'FAIL: sequence-reset mutant survived' >&2
    exit 1
fi
REPORT="$SCRATCH/app/build/test-results/testDebugUnitTest/TEST-com.aessam.comeoverhere.RealtimeCaptureInboxTest.xml"
if ! test -f "$REPORT" || ! rg -q 'Recovered frame must enter the existing guest timeline expected:&lt;ACCEPTED&gt; but was:&lt;DUPLICATE&gt;' "$REPORT"; then
    cat "$SCRATCH/mutant.log"
    echo 'FAIL: mutant did not fail for the intended playback assertion' >&2
    exit 1
fi
echo '[3/3] PASS: baseline passed; sequence-reset mutant killed by guest playout assertion'
