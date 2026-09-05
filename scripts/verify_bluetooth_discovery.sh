#!/bin/bash
# Software discovery gates. Physical radios require the separate two-phone check.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISCOVERY_JAVA="${GOH_ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
[[ -x "$DISCOVERY_JAVA/bin/java" ]] || { echo 'error: Java unavailable' >&2; exit 1; }
command -v swift >/dev/null || { echo 'error: Swift unavailable' >&2; exit 1; }
swift test --package-path "$PROJECT_ROOT/Packages/TourSessionCore" \
    --scratch-path "${GOH_SWIFT_SCRATCH:-/tmp/GetOverHereBluetoothCore}" --filter BluetoothRoomRecordTests
JAVA_HOME="$DISCOVERY_JAVA" "$PROJECT_ROOT/Android/gradlew" -p "$PROJECT_ROOT/Android" \
    :tour-session-core:test :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
xcodebuild -quiet -project "$PROJECT_ROOT/iOS/GetOverHere.xcodeproj" -scheme GetOverHere \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath "${GOH_IOS_DERIVED_DATA:-/tmp/GetOverHereBluetoothIOS}" \
    test -only-testing:GetOverHereTests/RoomDiscoveryIndexTests -only-testing:GetOverHereTests/ChannelServiceLifecycleTests
echo 'Bluetooth discovery software gate passed; Wi-Fi-off physical gate remains separate'
