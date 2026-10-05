#!/bin/bash
# Print real production Apple codec packets for a generated 440 Hz tone as wire-payload hex.
# Redirect to a temporary file, review, then explicitly update the retained regression fixture.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEC_SCRATCH="${GOH_SWIFT_SCRATCH:-/tmp/GetOverHereNativeCodecCore}"
command -v swiftc >/dev/null || { echo 'error: Swift toolchain is unavailable' >&2; exit 1; }
swift build --package-path "$PROJECT_ROOT/Packages/TourSessionCore" --scratch-path "$CODEC_SCRATCH" >&2
CODEC_BIN="$(swift build --package-path "$PROJECT_ROOT/Packages/TourSessionCore" --scratch-path "$CODEC_SCRATCH" --show-bin-path)"
[[ -f "$CODEC_BIN/libTourSessionCore.a" ]] || { echo 'error: Swift build did not produce libTourSessionCore.a' >&2; exit 1; }
CODEC_TEMP="$(mktemp -d /tmp/GetOverHereNativeCodec.XXXXXX)"
swiftc -parse-as-library -I "$CODEC_BIN" -L "$CODEC_BIN" -lTourSessionCore \
    "$PROJECT_ROOT/iOS/GetOverHere/Services/NativeAudioCodecCapabilities.swift" \
    "$PROJECT_ROOT/iOS/GetOverHere/Core/NativeRealtimeAudioCodec.swift" \
    "$PROJECT_ROOT/scripts/NativeCodecFixture.swift" -o "$CODEC_TEMP/fixture"
"$CODEC_TEMP/fixture"
rm "$CODEC_TEMP/fixture"
rmdir "$CODEC_TEMP"
