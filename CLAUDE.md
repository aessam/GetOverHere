# CLAUDE.md

Read `AGENTS.md` first. `TourGuideProductSpec.md` is the authoritative product contract. This repository contains native iOS and Android apps plus equivalent Swift and Kotlin GOH2 session cores.

## Current implemented architecture

- Discovery: Bonjour (`LocalControlPlane.swift`) and Android NSD (`LocalControlPlane.kt`) on a shared local Wi-Fi LAN. Internet is not required.
- Realtime lane: TCP port 50000, guide Float32 PCM audio to authenticated guests.
- Control lane: TCP port 50001, authoritative presentation, target, bearing, membership, and recovery state.
- Asset lane: TCP port 50002, request-driven 64 KiB chunks with resume, length checks, and SHA-256 verification.
- Admission: a random per-tour short code derives nonce-based mutual proofs independently for every lane.
- State: `TourSessionCore` Swift package and `:tour-session-core` Kotlin module must emit identical GOH2 bytes.

`UDPAudioPlane` is a legacy name; it is the TCP realtime implementation. The handshake authenticates admission but does not encrypt application payloads. Do not claim otherwise.

BLE, Android LocalOnlyHotspot, RAFT, and iOS Multipeer files remain compiled legacy/experimental code but are not selected by `NetworkCoordinator`. Native Wi-Fi Aware exists only behind the explicit lab and requires iOS 26.4 at runtime. It must not raise the production iOS 17 minimum.

The iOS production Wi-Fi Aware lane wrappers currently have no connection owner or product call sites. Do not claim that the normal app works over Aware until the isolated cross-platform probe and production wiring gates pass.

## Selected transport direction

- Wi-Fi Aware is the preferred no-infrastructure realtime/control/asset transport after both physical role directions pass.
- The existing LAN path is the guaranteed first-class full-capability floor, not an opportunistic legacy route.
- A bounded bitchat-style BLE overlay is planned for discovery, authentication bootstrap, current control state, membership, and degraded compressed voice if its physical gate passes. It is expected to be the common AP-less route for guests below the Aware OS/hardware floor.
- Route selection is per participant. Stable session/participant/stream/sequence identity suppresses duplicate delivery across concurrent routes.
- Aware overflow follows ADR-031: LAN, then validated BLE voice, then explicit control-only participation. Never exceed runtime Aware resources or evict an existing Aware guest.
- Android LocalOnlyHotspot/Wi-Fi Direct, portable routers, and cross-platform bridging of proprietary peer-to-peer Wi-Fi networks are not selected dependencies.
- Application payloads require route-independent authenticated encryption; ADR-023 admission authentication alone is insufficient.
- V1 has session-wide revocation only. End and restart the tour to rotate a leaked code and all derived keys.

`NextSession.md` is the canonical gate-by-gate execution plan. Execute P0 → P3 → P1; P1 is limited to four focused physical sessions or two engineering days. Do not start production Aware or BLE implementation before its preceding physical gate passes.

## Product boundaries

- Exactly one guide; guests never transmit microphone audio.
- Only the target pin coordinate crosses the network. Participant location and compass metadata stay local.
- The guide-selected Slides, Map, or Pointer screen is authoritative; guests may browse locally until the next guide change.
- Android owns the tour runtime in `ComeOverHereApp`, not `MainActivity`, so recreation cannot end a tour.
- iOS uses `AppCoordinator`; simulator audio is intentionally unsupported because `AVAudioEngine` can abort below Swift's throwable boundary.
- No Google Nearby production dependency, backend, account, analytics, cloud relay, or general-purpose/store-and-forward guest mesh. Only the bounded current-session BLE control/voice overlay in ADR-029 is in scope.

## Cross-platform contract changes

Change the Swift and Kotlin session cores in the same patch. Add roundtrip tests on both sides, extend deterministic CLI fixtures, and run `scripts/verify_tour_session.sh`. A semantic match is insufficient; exact bytes must match.

Do not add participant location, heading accuracy, or heading timestamps to shared payloads. The verifier scans for those privacy regressions.

## Build and test

```bash
scripts/verify_tour_session.sh

cd Android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew connectedDebugAndroidTest

xcodebuild -project iOS/GetOverHere.xcodeproj \
  -scheme GetOverHere \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The complete gate covers Swift/Kotlin protocol and authentication parity, host churn/fault simulation, Android JVM/APK integration, and iOS unit/integration tests. Physical devices remain mandatory for cross-platform audio, slides, target/pointer, background/reconnect, location/heading states, and native map rendering.

## Current compatibility

- iOS 17.0+, Xcode beta selected at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` on this machine.
- Android API 26+, Android Studio JBR, SDK at `/Users/aessam/Library/Android/sdk`.

Keep `ADR.md`, `LessonsLearned.md`, and append-only `ExperimentLog.md` current with decisions, root causes, exact commands, devices, and observed results.
