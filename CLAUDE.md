# CLAUDE.md

Read `AGENTS.md` first. `TourGuideProductSpec.md` is the authoritative product contract. This repository contains native iOS and Android apps plus equivalent Swift and Kotlin GOH2 session cores.

## Current implemented architecture

- Discovery: Bonjour/NSD, opt-in Bluetooth metadata plus native LE credit-based session endpoints, and explicit experimental Aware ownership. Endpoint-backed Bluetooth rooms can join; old metadata-only peers cannot. Internet is not required.
- Realtime lane: TCP port 50000, encrypted GOH2 v4 encoded audio (native Opus or AAC-LC); the local capture/playback boundary is PCM16.
- Control lane: TCP port 50001, authoritative presentation, target, bearing, membership, and recovery state.
- Asset lane: TCP port 50002, request-driven 60 KiB chunks with resume, length checks, SHA-256 verification and bounded fair/current-slide scheduling.
- Admission: rooms start open, with optional guide-editable code locking. TCP port 50003 uses admission v2 to bind a hidden per-tour media credential and the guide signing key to a fresh transcript. Room codes, media credentials and OS pairing PINs are separate (ADR-052/059). Native app pairs must both support v2; v1 remains only in core/explicit compatibility fixtures.
- State: `TourSessionCore` Swift package and `:tour-session-core` Kotlin module must emit identical GOH2 bytes.

`UDPAudioPlane` is a legacy name; it is the TCP realtime implementation. Each lane authenticates with the hidden admitted credential. Application payloads on all three LAN lanes are separately authenticated and encrypted as GOH2 v4 sealed frames. Locking or editing a room code does not revoke previously admitted guests. Short room codes remain vulnerable to offline guessing by an active malicious guide; they do not establish guide identity.

Legacy BLE control-plane files remain unselected; `LocalControlPlane` owns the new Bluetooth/Aware endpoint adapters. LocalOnlyHotspot, RAFT leader election, Multipeer, and the chat/file/walkie-talkie stubs were deleted (ADR-050). Native Wi-Fi Aware requires iOS 26.4 at runtime; the production iOS floor remains 17. Android BLE sessions require API 29+, Aware ownership API 34+.

`NearbySocketBridge` routes admission and sealed media protocols over native byte connections. It is not a remote-IP discovery mechanism or an arbitrary proxy. Typed nearby routes retain Bluetooth/Aware provenance; the loopback adapter is never a LAN address. Native guide frames now use one GOS1 signer across all lanes; admission-bound guide-key pinning rejects same-session substitution. Open-room first contact remains unverified human identity. Signed native relaying remains unimplemented. Shared software budgets and 30-member socket tests do not establish radio/group capacity. Direct Android BLE/Aware historical fixtures have physical evidence; current iPhone, locked-device, group and endurance acceptance remain open.

Android Aware compatibility PIN/NDP uses `_goh-andr._tcp`. The separately gated public system-paired subscriber candidate uses Apple's `_goh-tour._tcp`, requires full SDK37.2 plus documented keypad/pairing/resources and allows35s setup. System-paired Android publishing has an unresolved public endpoint-bootstrap contract; do not add dummy keys, fixed ports or private API workarounds. Native mixed Aware bytes are unqualified. Keep iOS26.4 guards and the iOS17 baseline. See the current implementation section of `NextSession.md`, not historical checkpoints, for delivery status.

## Selected transport direction

- Wi-Fi Aware is the preferred no-infrastructure realtime/control/asset transport after both physical role directions pass.
- The existing LAN path is the guaranteed first-class full-capability floor, not an opportunistic legacy route.
- A bounded bitchat-style BLE overlay is planned for discovery, authentication bootstrap, current control state, membership, and degraded compressed voice if its physical gate passes. It is expected to be the common AP-less route for guests below the Aware OS/hardware floor.
- Route selection is per participant. Stable session/participant/stream/sequence identity suppresses duplicate delivery across concurrent routes.
- Aware overflow follows ADR-031: LAN, then validated BLE voice, then explicit control-only participation. Never exceed runtime Aware resources or evict an existing Aware guest.
- Android LocalOnlyHotspot/Wi-Fi Direct, portable routers, and cross-platform bridging of proprietary peer-to-peer Wi-Fi networks are not selected dependencies.
- Application payloads require route-independent authenticated encryption; ADR-023 admission authentication alone is insufficient.
- Encrypt a logical frame once at creation and route the immutable sealed bytes. Socket writers never encrypt or allocate nonces. Reusing one frame identity with different plaintext is a fatal protocol error.
- Encrypted GOH2 is a hard major-version break. New builds expose legacy peers as an explicit version mismatch and never downgrade to plaintext.
- The product has session-wide revocation only. End and restart the tour to rotate the hidden media credential and revoke admitted guests. Editing the visible room code changes future admission only.

`NextSession.md` is the canonical execution plan. The September 5 user instruction changes delivery to one integrated candidate: implement the remaining BLE admission/control/voice, Aware ownership, hybrid routing, and asset behavior before requesting physical feedback. Run software gates and create focused commits throughout. Missing or locked devices do not block implementation. Physical gates remain mandatory for acceptance and product claims, not prerequisites for experimental coding. Keep unqualified routes explicitly experimental and preserve the stable LAN baseline. The physical Aware investigation remains limited to four focused sessions or two engineering days.

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
