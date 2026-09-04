#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_CORE="$PROJECT_ROOT/iOS/GetOverHere/Core"
ANDROID_CORE="$PROJECT_ROOT/Android/app/src/main/java/com/aessam/comeoverhere/core"

PAYLOAD_TRANSPORTS=(
    "$IOS_CORE/LocalSessionControlTransport.swift"
    "$IOS_CORE/UDPAudioPlane.swift"
    "$IOS_CORE/WiFiAwareSessionLaneTransport.swift"
    "$ANDROID_CORE/LocalSessionControlTransport.kt"
    "$ANDROID_CORE/UDPAudioPlane.kt"
)

fail_on_match() {
    local description="$1"
    local pattern="$2"
    shift 2
    local matches
    if matches="$(rg -n -U "$pattern" "$@")"; then
        echo "error: $description" >&2
        echo "$matches" >&2
        exit 1
    fi
}

require_match() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if ! rg -q "$pattern" "$file"; then
        echo "error: $description: $file" >&2
        exit 1
    fi
}

fail_on_match \
    "a production transport decodes a plaintext GOH2 session envelope" \
    '(^|[^[:alnum:]_])SessionEnvelope\.decode\(' \
    "${PAYLOAD_TRANSPORTS[@]}"

fail_on_match \
    "a Wi-Fi Aware wrapper bypasses encoded, encrypted realtime frames" \
    'lane\.send\s*\(\s*kind:\s*\.audioFrame\s*,\s*payload:\s*data' \
    "$IOS_CORE/WiFiAwareSessionLaneTransport.swift"

fail_on_match \
    "a handshake writes a logical envelope without sealing it" \
    'writeFrame\s*\([^\n]*(challengeEnvelope|helloEnvelope|welcome)\.encode\s*\(' \
    "${PAYLOAD_TRANSPORTS[@]}"

fail_on_match \
    "raw Float32 PCM returned to a production audio path" \
    'pcmFormatFloat32|ENCODING_PCM_FLOAT|ByteBuffer[^\n]*putFloat' \
    "$PROJECT_ROOT/iOS/GetOverHere" \
    "$ANDROID_CORE" \
    "$PROJECT_ROOT/Android/app/src/main/java/com/aessam/comeoverhere/service"

for transport in "${PAYLOAD_TRANSPORTS[@]}"; do
    require_match "production transport has no frame sealer" 'SessionFrameSealer' "$transport"
    require_match "production transport has no sealed-envelope decoder" 'SealedSessionEnvelope\.decode' "$transport"
done

# Retired plaintext or hotspot transports are deleted (ADR-050); an existence check cannot pass
# silently the way an rg over a missing path did (rg exits 2, the audit's `if` was false).
RETIRED_FILES=(
    "$IOS_CORE/MultipeerAudioPlane.swift"
    "$IOS_CORE/MultipeerTransport.swift"
    "$IOS_CORE/WiFiHotspotJoiner.swift"
    "$IOS_CORE/LeaderElection.swift"
    "$ANDROID_CORE/WiFiHotspotManager.kt"
    "$ANDROID_CORE/LeaderElection.kt"
)
for retired in "${RETIRED_FILES[@]}"; do
    if [[ -e "$retired" ]]; then
        echo "error: retired transport returned: $retired" >&2
        exit 1
    fi
done

if rg -q 'HotspotConfiguration' "$PROJECT_ROOT/iOS/GetOverHere/GetOverHere.entitlements"; then
    echo "error: hotspot entitlement returned without a hotspot owner" >&2
    exit 1
fi

if rg -n 'WiFiAwareAudioPlane\s*\(' "$PROJECT_ROOT/iOS/GetOverHere" \
    | rg -v 'final class WiFiAwareAudioPlane' >/dev/null; then
    echo "error: unqualified Wi-Fi Aware audio wrapper was made reachable" >&2
    exit 1
fi

echo "Encrypted session-path audit passed"
