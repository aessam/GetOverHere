#!/bin/bash
# Reproduce Apple production-codec -> Android native-decoder interoperability.
# Uses generated tone fixtures, never microphone recordings. Select emulator or physical serial.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEC_JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
CODEC_ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
CODEC_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
[[ -x "$CODEC_JAVA_HOME/bin/java" ]] || { echo 'error: Java is unavailable' >&2; exit 1; }
[[ -x "$CODEC_ADB" ]] || { echo 'error: adb is unavailable' >&2; exit 1; }
[[ "$("$CODEC_ADB" -s "$CODEC_SERIAL" get-state)" == device ]] || { echo 'error: selected device is unavailable' >&2; exit 1; }
[[ -s "$PROJECT_ROOT/Android/app/src/androidTest/assets/apple-native-codec.hex" ]] || { echo 'error: Apple codec fixture is missing' >&2; exit 1; }
echo "[1/2] Cleanup and streaming PCM conversion regressions"
JAVA_HOME="$CODEC_JAVA_HOME" "$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" :app:testDebugUnitTest \
    --tests '*PlayoutClockTest' --tests '*Pcm16VoiceResamplerTest'
echo "[2/2] Apple packets, native PCM duration, and encrypted transport on $CODEC_SERIAL"
ANDROID_SERIAL="$CODEC_SERIAL" JAVA_HOME="$CODEC_JAVA_HOME" "$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" \
    connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.NativeRealtimeAudioCodecTest
echo "Native codec interoperability passed on $CODEC_SERIAL"
