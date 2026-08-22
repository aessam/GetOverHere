#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_PACKAGE="$PROJECT_ROOT/Packages/TourSessionCore"
ANDROID_ROOT="$PROJECT_ROOT/Android"
ANDROID_JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
SWIFT_SCRATCH="${GOH_SWIFT_SCRATCH:-/tmp/GetOverHereTourSessionSwift}"
KOTLIN_CLI="$ANDROID_ROOT/tour-session-cli/build/install/tour-session-cli/bin/tour-session-cli"
EXPECTED="initial=slides:0|guide=map:1,pointer:2|guest=pointer:2|stale=pointer:2|late=pointer:2"

SWIFT_BIN="$(swift build --disable-sandbox --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_SCRATCH" --show-bin-path)/tour-session-swift"

(
    cd "$ANDROID_ROOT"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew :tour-session-cli:installDist
)

SWIFT_RESULT="$($SWIFT_BIN focus)"
KOTLIN_RESULT="$(JAVA_HOME="$ANDROID_JAVA_HOME" "$KOTLIN_CLI" focus)"

if [[ "$SWIFT_RESULT" != "$EXPECTED" || "$KOTLIN_RESULT" != "$EXPECTED" ]]; then
    echo "error: guide-selected shared screen is not authoritative across Swift and Kotlin" >&2
    echo "swift=$SWIFT_RESULT" >&2
    echo "kotlin=$KOTLIN_RESULT" >&2
    exit 1
fi

echo "Shared-screen reproduction passed"
