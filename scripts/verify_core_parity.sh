#!/bin/bash

# Cross-platform core parity gate (DSCN-3, ADR-051): Swift and Kotlin session-core tests, both
# CLIs, and a byte-exact compare of every argument-free fixture subcommand. No app build, no
# simulator, no emulator, no lint, and no toolchain mutation: CI selects the toolchain before
# calling this script, and a developer machine is never changed by it.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_PACKAGE="$PROJECT_ROOT/Packages/TourSessionCore"
ANDROID_ROOT="$PROJECT_ROOT/Android"
ANDROID_JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
SWIFT_SCRATCH="${GOH_SWIFT_SCRATCH:-/tmp/GetOverHereCoreParitySwift}"
SWIFT_MODULE_CACHE="${GOH_SWIFT_MODULE_CACHE:-/tmp/GetOverHereCoreParitySwiftModuleCache}"
KOTLIN_CLI="$ANDROID_ROOT/tour-session-cli/build/install/tour-session-cli/bin/tour-session-cli"

mkdir -p "$SWIFT_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"

# The toolchain is resolved from the environment (FND-14); print it so a run is attributable.
echo "ANDROID_JAVA_HOME=$ANDROID_JAVA_HOME"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift is not available" >&2
    exit 1
fi
swift --version

if [[ ! -x "$ANDROID_JAVA_HOME/bin/java" ]]; then
    echo "error: Java not found under $ANDROID_JAVA_HOME" >&2
    exit 1
fi

if [[ ! -x "$ANDROID_ROOT/gradlew" ]]; then
    echo "error: Android Gradle wrapper is missing" >&2
    exit 1
fi

echo "[1/4] Swift core tests"
swift test --disable-sandbox --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_SCRATCH"

echo "[2/4] Kotlin core tests and CLI install"
(
    cd "$ANDROID_ROOT"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew :tour-session-core:test :tour-session-cli:installDist
)

echo "[3/4] CLI binaries"
swift build --disable-sandbox --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_SCRATCH" --product tour-session-swift
SWIFT_BIN="$(swift build --disable-sandbox --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_SCRATCH" --show-bin-path)/tour-session-swift"
if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "error: Swift CLI is not executable at $SWIFT_BIN" >&2
    exit 1
fi
if [[ ! -x "$KOTLIN_CLI" ]]; then
    echo "error: Kotlin CLI is not executable at $KOTLIN_CLI" >&2
    exit 1
fi

echo "[4/4] Byte-exact Swift/Kotlin fixture parity"
# Every argument-free subcommand both CLIs expose at HEAD; extend this list when a fixture is added.
for command in fixture encrypted-fixture audio-fixture handshake realtime-fixture nearby-fixture state auth faults playout recovery focus; do
    SWIFT_OUT="$("$SWIFT_BIN" "$command")"
    KOTLIN_OUT="$(JAVA_HOME="$ANDROID_JAVA_HOME" "$KOTLIN_CLI" "$command")"
    [[ -n "$SWIFT_OUT" && -n "$KOTLIN_OUT" ]] || { echo "error: $command produced no output" >&2; exit 1; }
    [[ "$SWIFT_OUT" == "$KOTLIN_OUT" ]] || { echo "error: Swift and Kotlin differ for $command" >&2; exit 1; }
    echo "ok $command bytes=${#SWIFT_OUT}"
done

JAVA_HOME="$ANDROID_JAVA_HOME" python3 "$PROJECT_ROOT/scripts/verify_room_admission.py" "$SWIFT_BIN" "$KOTLIN_CLI"
echo "Core parity passed"
