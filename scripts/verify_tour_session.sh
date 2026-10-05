#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_PACKAGE="$PROJECT_ROOT/Packages/TourSessionCore"
ANDROID_ROOT="$PROJECT_ROOT/Android"
ANDROID_JAVA_HOME="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
SWIFT_SCRATCH="${GOH_SWIFT_SCRATCH:-/tmp/GetOverHereTourSessionSwift}"
SWIFT_MODULE_CACHE="${GOH_SWIFT_MODULE_CACHE:-/tmp/GetOverHereTourSessionSwiftModuleCache}"
KOTLIN_CLI="$ANDROID_ROOT/tour-session-cli/build/install/tour-session-cli/bin/tour-session-cli"
XCODE_DEVELOPER_DIR="${GOH_XCODE_DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo /Users/aessam/Downloads/Xcode-beta.app/Contents/Developer)}"
IOS_DERIVED_DATA="${GOH_IOS_DERIVED_DATA:-/tmp/GetOverHereTourSessionDerived}"
IOS_MODULE_CACHE="${GOH_IOS_MODULE_CACHE:-/tmp/GetOverHereTourSessionModuleCache}"
IOS_SIMULATOR_NAME="${GOH_IOS_SIMULATOR_NAME:-iPhone 17}"
IOS_DESTINATION="${GOH_IOS_DESTINATION:-platform=iOS Simulator,name=$IOS_SIMULATOR_NAME}"

mkdir -p "$SWIFT_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"

# The toolchain is resolved from the environment (FND-14); print it so a run is attributable.
echo "ANDROID_JAVA_HOME=$ANDROID_JAVA_HOME"
echo "XCODE_DEVELOPER_DIR=$XCODE_DEVELOPER_DIR"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift is not available" >&2
    exit 1
fi

if [[ ! -x "$ANDROID_JAVA_HOME/bin/java" ]]; then
    echo "error: Java not found under $ANDROID_JAVA_HOME" >&2
    exit 1
fi

if [[ ! -x "$ANDROID_ROOT/gradlew" ]]; then
    echo "error: Android Gradle wrapper is missing" >&2
    exit 1
fi

if [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "error: xcodebuild not found under $XCODE_DEVELOPER_DIR" >&2
    exit 1
fi

# Fail before the long steps when the iOS destination cannot exist (xcodebuild otherwise exits 70 at step 9).
echo "IOS_DESTINATION=$IOS_DESTINATION"
if [[ -z "${GOH_IOS_DESTINATION:-}" ]] && ! DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun simctl list devices available \
    | grep -Fq "    $IOS_SIMULATOR_NAME ("; then
    echo "error: no available simulator named '$IOS_SIMULATOR_NAME'. Set GOH_IOS_SIMULATOR_NAME or GOH_IOS_DESTINATION. Available:" >&2
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun simctl list devices available | grep -E '^    iPhone' >&2
    exit 1
fi

echo "[1/9] Swift protocol and registry tests"
swift test --disable-sandbox --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_SCRATCH"
swift test --disable-sandbox --package-path "$PROJECT_ROOT/Packages/LocalLinkSecurity" \
    --scratch-path "${GOH_LINK_SECURITY_SCRATCH:-/tmp/GetOverHereTourSessionLinkSecurity}"

echo "[2/9] Kotlin protocol and registry tests"
(
    cd "$ANDROID_ROOT"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew :tour-session-core:test :tour-session-cli:installDist
)

SWIFT_BIN="$(swift build --disable-sandbox --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_SCRATCH" --show-bin-path)/tour-session-swift"

JAVA_HOME="$ANDROID_JAVA_HOME" python3 "$PROJECT_ROOT/scripts/verify_room_admission.py" "$SWIFT_BIN" "$KOTLIN_CLI"
JAVA_HOME="$ANDROID_JAVA_HOME" python3 "$PROJECT_ROOT/scripts/verify_room_admission_v2.py" "$SWIFT_BIN" "$KOTLIN_CLI"
JAVA_HOME="$ANDROID_JAVA_HOME" python3 "$PROJECT_ROOT/scripts/verify_guide_signatures.py" "$SWIFT_BIN" "$KOTLIN_CLI"
JAVA_HOME="$ANDROID_JAVA_HOME" python3 "$PROJECT_ROOT/scripts/verify_gateway_protocol.py" "$SWIFT_BIN" "$KOTLIN_CLI"

run_kotlin() {
    JAVA_HOME="$ANDROID_JAVA_HOME" "$KOTLIN_CLI" "$@"
}

echo "[3/9] Exact Swift/Kotlin wire bytes"
SWIFT_NEARBY="$($SWIFT_BIN nearby-fixture)"
KOTLIN_NEARBY="$(run_kotlin nearby-fixture)"
[[ -n "$SWIFT_NEARBY" && "$SWIFT_NEARBY" == "$KOTLIN_NEARBY" ]] || { echo 'error: nearby selector/expiry parity failed' >&2; exit 1; }
SWIFT_DISCOVERY_V2="$($SWIFT_BIN bluetooth-v2-fixture)"
KOTLIN_DISCOVERY_V2="$(run_kotlin bluetooth-v2-fixture)"
[[ -n "$SWIFT_DISCOVERY_V2" && "$SWIFT_DISCOVERY_V2" == "$KOTLIN_DISCOVERY_V2" ]] || { echo 'error: nearby admission v2 discovery parity failed' >&2; exit 1; }
SWIFT_READINESS="$($SWIFT_BIN audio-readiness-fixture)"
KOTLIN_READINESS="$(run_kotlin audio-readiness-fixture)"
[[ "$SWIFT_READINESS" == '01020102030405060708' && "$SWIFT_READINESS" == "$KOTLIN_READINESS" ]] || { echo 'error: renderer readiness parity failed' >&2; exit 1; }
SWIFT_HEX="$($SWIFT_BIN fixture)"
KOTLIN_HEX="$(run_kotlin fixture)"
if [[ "$SWIFT_HEX" != "$KOTLIN_HEX" ]]; then
    echo "error: Swift and Kotlin encoded different GOH2 bytes" >&2
    exit 1
fi

SWIFT_ENCRYPTED_HEX="$($SWIFT_BIN encrypted-fixture)"
KOTLIN_ENCRYPTED_HEX="$(run_kotlin encrypted-fixture)"
if [[ "$SWIFT_ENCRYPTED_HEX" != "$KOTLIN_ENCRYPTED_HEX" ]]; then
    echo "error: Swift and Kotlin encoded different encrypted session bytes" >&2
    exit 1
fi

SWIFT_AUDIO_HEX="$($SWIFT_BIN audio-fixture)"
KOTLIN_AUDIO_HEX="$(run_kotlin audio-fixture)"
if [[ "$SWIFT_AUDIO_HEX" != "$KOTLIN_AUDIO_HEX" ]]; then
    echo "error: Swift and Kotlin encoded different realtime audio bytes" >&2
    exit 1
fi

# Fixture outputs are assigned to variables first so a crashed CLI fails errexit instead of
# comparing empty against empty inside a condition; the [[ -n ]] guards make that explicit.
SWIFT_HANDSHAKE_HEX="$($SWIFT_BIN handshake)"
[[ -n "$SWIFT_HANDSHAKE_HEX" ]] || { echo "error: Swift handshake fixture produced no output" >&2; exit 1; }
KOTLIN_HANDSHAKE_HEX="$(run_kotlin handshake)"
[[ -n "$KOTLIN_HANDSHAKE_HEX" ]] || { echo "error: Kotlin handshake fixture produced no output" >&2; exit 1; }
if [[ "$SWIFT_HANDSHAKE_HEX" != "$KOTLIN_HANDSHAKE_HEX" ]]; then
    echo "error: Swift and Kotlin encoded different authChallenge/welcome/leave bytes" >&2
    exit 1
fi

SWIFT_REALTIME_HEX="$($SWIFT_BIN realtime-fixture)"
[[ -n "$SWIFT_REALTIME_HEX" ]] || { echo "error: Swift realtime fixture produced no output" >&2; exit 1; }
KOTLIN_REALTIME_HEX="$(run_kotlin realtime-fixture)"
[[ -n "$KOTLIN_REALTIME_HEX" ]] || { echo "error: Kotlin realtime fixture produced no output" >&2; exit 1; }
if [[ "$SWIFT_REALTIME_HEX" != "$KOTLIN_REALTIME_HEX" ]]; then
    echo "error: Swift and Kotlin sealed different realtime audioFrame envelopes" >&2
    exit 1
fi

SWIFT_STATE_HEX="$($SWIFT_BIN state)"
[[ -n "$SWIFT_STATE_HEX" ]] || { echo "error: Swift state fixture produced no output" >&2; exit 1; }
KOTLIN_STATE_HEX="$(run_kotlin state)"
[[ -n "$KOTLIN_STATE_HEX" ]] || { echo "error: Kotlin state fixture produced no output" >&2; exit 1; }
if [[ "$SWIFT_STATE_HEX" != "$KOTLIN_STATE_HEX" ]]; then
    echo "error: presentation, bearing, target, shared-screen, slide/tour-pack tie-break, request, status, or asset-chunk bytes differ" >&2
    exit 1
fi

# Elements 5 (assetManifest) and 6 (tourPackManifest) each carry one U+FF5E and one U+1F5FA ID
# sharing an order. UTF-8 order puts ef bd 9e before f0 9f 97 ba; UTF-16 order would invert it.
# Each element is checked on its own so one correct element cannot mask the other.
IFS='|' read -r -a SWIFT_STATE_ELEMENTS <<< "$SWIFT_STATE_HEX"
for INDEX in 4 5; do
    if [[ "${SWIFT_STATE_ELEMENTS[$INDEX]:-}" != *efbd9e*f09f97ba* ]]; then
        echo "error: manifest tie-break in state element $((INDEX + 1)) is not UTF-8 byte order (U+FF5E must precede U+1F5FA)" >&2
        exit 1
    fi
done

echo "[4/9] Cross-language decode and participant churn"
SWIFT_DESCRIPTION="$($SWIFT_BIN decode "$KOTLIN_HEX")"
KOTLIN_DESCRIPTION="$(run_kotlin decode "$SWIFT_HEX")"
if [[ "$SWIFT_DESCRIPTION" != "$KOTLIN_DESCRIPTION" ]]; then
    echo "error: Swift and Kotlin decoded different GOH2 values" >&2
    exit 1
fi

SWIFT_ENCRYPTED_DESCRIPTION="$($SWIFT_BIN decode-encrypted "$KOTLIN_ENCRYPTED_HEX")"
KOTLIN_ENCRYPTED_DESCRIPTION="$(run_kotlin decode-encrypted "$SWIFT_ENCRYPTED_HEX")"
if [[ "$SWIFT_ENCRYPTED_DESCRIPTION" != "$KOTLIN_ENCRYPTED_DESCRIPTION" ]]; then
    echo "error: Swift and Kotlin decoded different encrypted session values" >&2
    exit 1
fi

SWIFT_STATE_DESC="$($SWIFT_BIN decode "$KOTLIN_STATE_HEX")"
[[ -n "$SWIFT_STATE_DESC" ]] || { echo "error: Swift could not decode Kotlin state bytes" >&2; exit 1; }
KOTLIN_STATE_DESC="$(run_kotlin decode "$SWIFT_STATE_HEX")"
[[ -n "$KOTLIN_STATE_DESC" ]] || { echo "error: Kotlin could not decode Swift state bytes" >&2; exit 1; }
if [[ "$SWIFT_STATE_DESC" != "$KOTLIN_STATE_DESC" ]]; then
    echo "error: Swift and Kotlin described different control/asset state values" >&2
    exit 1
fi

SWIFT_HANDSHAKE_DESC="$($SWIFT_BIN decode "$KOTLIN_HANDSHAKE_HEX")"
[[ -n "$SWIFT_HANDSHAKE_DESC" ]] || { echo "error: Swift could not decode Kotlin handshake bytes" >&2; exit 1; }
KOTLIN_HANDSHAKE_DESC="$(run_kotlin decode "$SWIFT_HANDSHAKE_HEX")"
[[ -n "$KOTLIN_HANDSHAKE_DESC" ]] || { echo "error: Kotlin could not decode Swift handshake bytes" >&2; exit 1; }
if [[ "$SWIFT_HANDSHAKE_DESC" != "$KOTLIN_HANDSHAKE_DESC" ]]; then
    echo "error: Swift and Kotlin described different handshake values" >&2
    exit 1
fi

SWIFT_REALTIME_DESC="$($SWIFT_BIN decode-encrypted "$KOTLIN_REALTIME_HEX")"
[[ -n "$SWIFT_REALTIME_DESC" ]] || { echo "error: Swift could not open Kotlin realtime bytes" >&2; exit 1; }
KOTLIN_REALTIME_DESC="$(run_kotlin decode-encrypted "$SWIFT_REALTIME_HEX")"
[[ -n "$KOTLIN_REALTIME_DESC" ]] || { echo "error: Kotlin could not open Swift realtime bytes" >&2; exit 1; }
if [[ "$SWIFT_REALTIME_DESC" != "$KOTLIN_REALTIME_DESC" ]]; then
    echo "error: Swift and Kotlin described different sealed realtime values" >&2
    exit 1
fi

SWIFT_AUDIO_DESC="$($SWIFT_BIN decode-audio "$KOTLIN_AUDIO_HEX")"
[[ -n "$SWIFT_AUDIO_DESC" ]] || { echo "error: Swift could not decode Kotlin audio payload" >&2; exit 1; }
KOTLIN_AUDIO_DESC="$(run_kotlin decode-audio "$SWIFT_AUDIO_HEX")"
[[ -n "$KOTLIN_AUDIO_DESC" ]] || { echo "error: Kotlin could not decode Swift audio payload" >&2; exit 1; }
if [[ "$SWIFT_AUDIO_DESC" != "$KOTLIN_AUDIO_DESC" ]]; then
    echo "error: Swift and Kotlin described different encoded audio frame values" >&2
    exit 1
fi

for COUNT in 1 8 20 50; do
    SWIFT_RESULT="$($SWIFT_BIN simulate "$COUNT")"
    KOTLIN_RESULT="$(run_kotlin simulate "$COUNT")"
    EXPECTED="peak=$COUNT|reconnect=$COUNT|staleDisconnect=$COUNT|final=0"
    if [[ "$SWIFT_RESULT" != "$EXPECTED" || "$KOTLIN_RESULT" != "$EXPECTED" ]]; then
        echo "error: participant simulation failed at $COUNT guests" >&2
        exit 1
    fi
done

echo "[5/9] Realtime loss, duplicate, and reorder audit"
EXPECTED_FAULTS="unique=5|duplicates=1|reordered=1|missing=2"
if [[ "$($SWIFT_BIN faults)" != "$EXPECTED_FAULTS" || "$(run_kotlin faults)" != "$EXPECTED_FAULTS" ]]; then
    echo "error: realtime fault audit mismatch" >&2
    exit 1
fi

EXPECTED_PLAYOUT="w,w,f1,f2,w,c3,f4,f10,f11,w"
SWIFT_PLAYOUT="$($SWIFT_BIN playout)"
KOTLIN_PLAYOUT="$(run_kotlin playout)"
if [[ "$SWIFT_PLAYOUT" != "$EXPECTED_PLAYOUT" || "$KOTLIN_PLAYOUT" != "$EXPECTED_PLAYOUT" ]]; then
    echo "error: clocked playout concealment/resync mismatch" >&2
    exit 1
fi

EXPECTED_FOCUS="initial=slides:0|guide=map:1,pointer:2|guest=pointer:2|stale=pointer:2|late=pointer:2"
if [[ "$($SWIFT_BIN focus)" != "$EXPECTED_FOCUS" || "$(run_kotlin focus)" != "$EXPECTED_FOCUS" ]]; then
    echo "error: guide-selected shared-screen simulation failed" >&2
    exit 1
fi

SWIFT_AUTH_HEX="$($SWIFT_BIN auth)"
[[ -n "$SWIFT_AUTH_HEX" ]] || { echo "error: Swift auth fixture produced no output" >&2; exit 1; }
KOTLIN_AUTH_HEX="$(run_kotlin auth)"
[[ -n "$KOTLIN_AUTH_HEX" ]] || { echo "error: Kotlin auth fixture produced no output" >&2; exit 1; }
if [[ "$SWIFT_AUTH_HEX" != "$KOTLIN_AUTH_HEX" ]]; then
    echo "error: Swift and Kotlin authentication proofs differ" >&2
    exit 1
fi

EXPECTED_RECOVERY="lateSlide=gate-left|lateTarget=9|reconnect=1|staleTarget=9|replacementTarget=10|missing=1|readyAfterFetch=true"
if [[ "$($SWIFT_BIN recovery)" != "$EXPECTED_RECOVERY" || "$(run_kotlin recovery)" != "$EXPECTED_RECOVERY" ]]; then
    echo "error: late-join, reconnect, missing-asset, or target-replacement simulation failed" >&2
    exit 1
fi

if rg -n -i 'participant(location|latitude|longitude)|guest(location|latitude|longitude)|guide(location|latitude|longitude)' \
    "$SWIFT_PACKAGE/Sources/TourSessionCore" \
    "$ANDROID_ROOT/tour-session-core/src/main" >/dev/null; then
    echo "error: participant location appeared in a shared wire-contract module" >&2
    exit 1
fi

if rg -n 'accuracyMilliDegrees|sampledAtNanoseconds' \
    "$SWIFT_PACKAGE/Sources/TourSessionCore" \
    "$ANDROID_ROOT/tour-session-core/src/main" >/dev/null; then
    echo "error: local compass metadata appeared in the shared bearing payload" >&2
    exit 1
fi

if rg -n 'UIDevice\.current\.name|Command observed.*\$command|BLE cmd.*String\(data:|SSID=\$\{|WiFi joined:|validated guest.*displayName|Session guest joined.*displayName|GATT client (connected|disconnected):.*address' \
    "$PROJECT_ROOT/iOS/GetOverHere" \
    "$ANDROID_ROOT/app/src/main" >/dev/null; then
    echo "error: credential or persistent participant metadata appeared in application logs" >&2
    exit 1
fi

if rg -n 'Logger\..*error\.localizedDescription|fputs\(.*error\.localizedDescription' \
    "$PROJECT_ROOT/iOS/GetOverHere" >/dev/null; then
    echo "error: an unredacted runtime error can enter an iOS application log" >&2
    exit 1
fi

if rg -n 'Log\.[vdiwe]\([^\n]*,\s*error\)|System\.err\.println.*error\.(message|localizedMessage)' \
    "$ANDROID_ROOT/app/src/main" >/dev/null; then
    echo "error: an unredacted runtime error can enter an Android application log" >&2
    exit 1
fi

if rg -n 'play-services-nearby|com\.google\.android\.gms\.nearby' \
    "$ANDROID_ROOT/app/build.gradle.kts" \
    "$ANDROID_ROOT/app/src/main" \
    "$ANDROID_ROOT/gradle/libs.versions.toml" >/dev/null; then
    echo "error: unused Google Nearby dependency returned to the production Android path" >&2
    exit 1
fi

if rg -n 'WiFiAwareSessionTransport|enableWiFiAware|awareAnnouncements|awareSnapshot|hostWiFiAware|connectWiFiAware' \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/NetworkCoordinator.kt" \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/service/ChannelService.kt" \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/ui/AppViewModel.kt" \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/ui/ChannelScreen.kt" >/dev/null; then
    echo "error: Wi-Fi Aware returned to production before the physical P1 gate passed" >&2
    exit 1
fi

if rg -n 'commandCont\.yield.*channelEnded|_commands\.tryEmit.*ChannelEnded' \
    "$PROJECT_ROOT/iOS/GetOverHere/Core/LocalControlPlane.swift" \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/LocalControlPlane.kt" >/dev/null; then
    echo "error: discovery loss is again being treated as authoritative session end" >&2
    exit 1
fi

if rg -n 'Task \{ @concurrent|sendQueue|sendExecutor' \
    "$PROJECT_ROOT/iOS/GetOverHere/Core/UDPAudioPlane.swift" \
    "$PROJECT_ROOT/iOS/GetOverHere/Core/LocalSessionControlTransport.swift" \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt" \
    "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/LocalSessionControlTransport.kt" >/dev/null; then
    echo "error: production socket I/O again uses the cooperative pool or one shared send queue" >&2
    exit 1
fi

# One rg per file: a single rg over two files exits 0 when either matches.
if ! rg -q 'TCP_NODELAY' "$PROJECT_ROOT/iOS/GetOverHere/Core/UDPAudioPlane.swift" \
    || ! rg -q 'tcpNoDelay = true' "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt"; then
    echo "error: realtime audio sockets no longer disable Nagle" >&2
    exit 1
fi

if ! rg -q '"audio\.encode\.seal"' "$PROJECT_ROOT/iOS/GetOverHere/Core/UDPAudioPlane.swift" \
    || ! rg -q '"audio-encode-seal"' "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt"; then
    echo "error: realtime encode/seal is no longer isolated on a dedicated worker" >&2
    exit 1
fi
if rg -q '@Synchronized\s+override fun sendAudio' "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt"; then
    echo "error: Android sendAudio again encodes on the caller thread" >&2
    exit 1
fi

if ! rg -q '"audio\.tcp\.playout"' "$PROJECT_ROOT/iOS/GetOverHere/Core/UDPAudioPlane.swift" \
    || ! rg -q '"goh2-audio-playout"' "$ANDROID_ROOT/app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt"; then
    echo "error: realtime playout is no longer clock-driven" >&2
    exit 1
fi

if rg -n 'outputBuffer\s*=\s*buffer|func startCapture\(\) -> AsyncStream' \
    "$PROJECT_ROOT/iOS/GetOverHere/Services/AudioEngine.swift" >/dev/null; then
    echo "error: failed iOS capture setup can still publish invalid or silent tour audio" >&2
    exit 1
fi

if rg 'IPHONEOS_DEPLOYMENT_TARGET = ' "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj/project.pbxproj" \
    | rg -v 'IPHONEOS_DEPLOYMENT_TARGET = 17\.0;' >/dev/null; then
    echo "error: an iOS target no longer uses the supported iOS 17 baseline" >&2
    exit 1
fi

if ! rg -q '\.iOS\(\.v17\),' "$SWIFT_PACKAGE/Package.swift"; then
    echo "error: TourSessionCore no longer supports the production iOS 17 baseline" >&2
    exit 1
fi

echo "[6/9] Encrypted production session-path audit"
"$PROJECT_ROOT/scripts/verify_no_plaintext_session_paths.sh"

echo "[7/9] Android API-floor and permission lint"
(
    cd "$ANDROID_ROOT"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew lintDebug
)

echo "[8/9] Android app integration, TCP loopback, and APK"
PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_ROOT/scripts/test_benchmark_android_aware.py"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$PROJECT_ROOT/scripts" -p 'test_gateway_tools.py' -v
(
    cd "$ANDROID_ROOT"
    JAVA_HOME="$ANDROID_JAVA_HOME" ./gradlew testDebugUnitTest assembleDebug
)

echo "[9/9] iOS app unit/integration suite in Simulator"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
CLANG_MODULE_CACHE_PATH="$IOS_MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$IOS_MODULE_CACHE" \
    "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" -quiet \
    -project "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj" \
    -scheme GetOverHere \
    -destination "$IOS_DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    test \
    -only-testing:GetOverHereTests

echo "Tour session verification passed"
