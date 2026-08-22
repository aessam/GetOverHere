# CLAUDE.md

Read `AGENTS.md` first. `TourGuideProductSpec.md` is the authoritative product contract. This repository contains native iOS and Android apps plus equivalent Swift and Kotlin GOH2 session cores.

## Live architecture

- Discovery: Bonjour (`LocalControlPlane.swift`) and Android NSD (`LocalControlPlane.kt`) on a shared local Wi-Fi LAN. Internet is not required.
- Realtime lane: TCP port 50000, guide Float32 PCM audio to authenticated guests.
- Control lane: TCP port 50001, authoritative presentation, target, bearing, membership, and recovery state.
- Asset lane: TCP port 50002, request-driven 64 KiB chunks with resume, length checks, and SHA-256 verification.
- Admission: a random per-tour short code derives nonce-based mutual proofs independently for every lane.
- State: `TourSessionCore` Swift package and `:tour-session-core` Kotlin module must emit identical GOH2 bytes.

`UDPAudioPlane` is a legacy name; it is the TCP realtime implementation. The handshake authenticates admission but does not encrypt application payloads. Do not claim otherwise.

BLE, Android LocalOnlyHotspot, RAFT, and iOS Multipeer files remain compiled legacy/experimental code but are not selected by `NetworkCoordinator`. Native Wi-Fi Aware exists only behind the explicit lab and requires iOS 26.4 at runtime. It must not raise the production iOS 17 minimum.

## Product boundaries

- Exactly one guide; guests never transmit microphone audio.
- Only the target pin coordinate crosses the network. Participant location and compass metadata stay local.
- The guide-selected Slides, Map, or Pointer screen is authoritative; guests may browse locally until the next guide change.
- Android owns the tour runtime in `ComeOverHereApp`, not `MainActivity`, so recreation cannot end a tour.
- iOS uses `AppCoordinator`; simulator audio is intentionally unsupported because `AVAudioEngine` can abort below Swift's throwable boundary.
- No Google Nearby production dependency, backend, account, analytics, cloud relay, or guest mesh.

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
