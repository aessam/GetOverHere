#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REVIEW_JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
[[ -x "$REVIEW_JAVA_HOME/bin/java" && -x "$ROOT/Android/gradlew" ]] || { echo 'Missing Java/Gradle'; exit 2; }
command -v swift >/dev/null || { echo 'Missing Swift'; exit 2; }
OUT="$(mktemp -d /tmp/GetOverHereSecurityReview.XXXXXX)"
echo "Review evidence: $OUT"
result=0
if ! swift test --disable-sandbox --package-path "$ROOT/scripts/review/gateway" \
    --scratch-path "$OUT/swift-build" > "$OUT/swift.log" 2>&1; then result=1; fi
if ! (cd "$ROOT/Android" && JAVA_HOME="$REVIEW_JAVA_HOME" ./gradlew :app:testDebugUnitTest \
    --init-script "$ROOT/scripts/review/gateway/android.init.gradle" \
    --tests com.aessam.comeoverhere.GatewaySecurityReviewTest) > "$OUT/android.log" 2>&1; then result=1; fi
echo "Review regression exit=$result (nonzero means unresolved regression or environment failure; inspect logs)."
echo "Logs: $OUT/swift.log $OUT/android.log"
exit "$result"
