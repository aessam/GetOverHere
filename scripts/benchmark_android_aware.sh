#!/bin/bash
# Explicit physical pair, test-only traffic over the production Aware adapter.
set -euo pipefail
BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_JAVA="${GOH_ANDROID_JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
[[ -x "$BENCH_JAVA/bin/java" ]] || { echo 'error: Android Studio JBR missing' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'error: python3 missing' >&2; exit 1; }
# Validate arguments/devices before spending time building or installing.
python3 "$BENCH_ROOT/scripts/benchmark_android_aware.py" --preflight-only "$@"
JAVA_HOME="$BENCH_JAVA" "$BENCH_ROOT/Android/gradlew" -p "$BENCH_ROOT/Android" :app:assembleDebug :app:assembleDebugAndroidTest
python3 "$BENCH_ROOT/scripts/benchmark_android_aware.py" "$@"
