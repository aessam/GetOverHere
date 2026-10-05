# GetOverHere

Offline tour-guide broadcasting for iOS and Android. One guide speaks; guests listen and receive synchronized slides, a shared map target, or a sightline pointer. The current verified build uses a local Wi-Fi LAN, which remains the guaranteed full-capability floor. Wi-Fi Aware and a bounded BLE control/voice route are gated options for tours without an access point. No route requires Internet access, accounts, a backend, or analytics.

## Product

- One authenticated guide-to-many-guests audio session.
- Ordered local-image slide deck with automatic guest presentation.
- Offline PMTiles map with one guide-selected target pin.
- Device-local user dot, distance, and direction. Participant locations never leave their phones.
- Magnetic sightline pointer for landmarks that are not map coordinates.
- Late-join and reconnect recovery for presentation, pin, pointer, and cached assets.
- Receiver/headset playback by default to prevent acoustic feedback; speaker is an explicit override.

The authoritative requirements and acceptance gates are in [TourGuideProductSpec.md](TourGuideProductSpec.md). Architecture decisions are in [ADR.md](ADR.md), and executed evidence is in [ExperimentLog.md](ExperimentLog.md).

## Current verified architecture

```text
                         local Wi-Fi LAN
                   Internet connection not needed
                              │
          ┌───────────────────┴───────────────────┐
          │                                       │
      guide phone                            guest phones
       iOS/Android                            iOS/Android
          │                                       │
          ├── TCP :50000, GOH2 realtime audio ───►│
          ├── TCP :50001, GOH2 control state ────►│
          └── TCP :50002, GOH2 asset chunks ─────►│
```

Bonjour on iOS and NSD on Android discover LAN guide sessions. The `Bluetooth room discovery` toggle now enables experimental direct joining over LE credit-based sockets, not just room-name previews. Both platforms implement admission, audio, control, and assets through the existing authenticated lanes. Android requires API 29+ for these sockets; older peers remain discovery-only. LAN guests stop scanning; Bluetooth guests stop scanning once their guide link is established and resume after route loss. Rooms start open, with optional guide-editable code locking; admission supplies a separate hidden media credential. Slide and map assets remain content-addressed, chunked, resumable, and SHA-256 verified.

The LAN path remains the preserved baseline. Experimental Wi-Fi Aware owns native connections outside the lab. Android compatibility mode uses a displayed device PIN, separate from room locking. A new, separately gated system-paired subscriber candidate requires Android37.2 and eligible hardware; Android system-paired publishing still lacks a supported endpoint bootstrap in this implementation. Mixed Aware is unqualified; use LAN or the experimental Bluetooth route for the currently implemented mixed path. Aware needs Wi-Fi enabled but no access point or Internet. Bluetooth is the route intended for a disabled Wi-Fi radio.

The September8 implementation uses admission v2 and pins the guide signing key across the session. Every authoritative native lane verifies signed guide frames before decryption. Update both apps together; old native admission versions are rejected explicitly. Audio-ready counts follow renderer reports, not merely joined sockets, and are not acoustic proof. Shared software connection budgets support testing 30 logical listeners but do not qualify 30 radio peers. Current coding/test status is in [NextSession.md](NextSession.md); the later single field round is [FieldAcceptance.md](FieldAcceptance.md).

Physical Android fixtures have passed admission, pointer state, exact asset bytes, and non-silent native audio over BLE with Wi-Fi disabled on both phones in both guide directions. Android Aware also passed both roles. This does not qualify iPhone interoperability, live radio-toggle recovery, locked phones, acoustic playback, large groups, or endurance. The implementation is direct, not the planned signed relay overlay. See ADR-056 and `NextSession.md` for remaining work; do not label the entire no-Wi-Fi product complete.

## Selected transport architecture

```text
BLE controlled relay overlay
  ├── discovery and authentication bootstrap
  ├── authoritative control and membership
  └── degraded compressed voice after physical acceptance
                    │
                    ▼
Per-participant route
  ├── Wi-Fi Aware preferred direct no-AP
  ├── local LAN guaranteed full-capability floor
  └── BLE degraded voice after physical acceptance
```

Android-hosted Wi-Fi and portable routers are not selected dependencies. The BLE overlay is bounded to the active tour and does not provide general-purpose or store-and-forward mesh routing. Aware and BLE voice must pass their physical gates before the product claims no-AP audio for a device or group; otherwise LAN remains required for audio. [NextSession.md](NextSession.md) contains the execution order and acceptance gates.

## Repository

```text
Packages/TourSessionCore/          Swift GOH2 contracts, registry, CLI, tests
Android/tour-session-core/         Equivalent Kotlin contracts and tests
Android/tour-session-cli/          Host simulation and fixture CLI
iOS/GetOverHere/                   Native iOS app
Android/app/                       Native Android app
scripts/verify_tour_session.sh     Complete host/simulator verification gate
TourGuideProductSpec.md            Authoritative product specification
ADR.md                             Architecture decisions
LessonsLearned.md                  Root causes and durable rules
ExperimentLog.md                   Commands, devices, and results
```

## Requirements

| Platform | Minimum |
|---|---:|
| iOS | 17.0 |
| Android | API 26 / Android 8.0 |

Physical devices are required for final audio, local-network, compass, location, background, and map-renderer acceptance.

## Verification

```bash
scripts/verify_tour_session.sh

# With the Android emulator already running: host gate, iOS UI, Android instrumentation.
scripts/verify_virtual_devices.sh

cd Android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew connectedDebugAndroidTest
```

The first command tests Swift and Kotlin protocol parity, exact wire bytes, authentication, participant churn at 1/8/20/50 guests, fault accounting, Android JVM integration/APK assembly, and the iOS Simulator suite.

`verify_virtual_devices.sh` additionally runs the full iOS UI and Android instrumented suites. It defaults to Android `emulator-5554` (override with `ANDROID_SERIAL`) and the iPhone 17 Pro simulator. Unsupported simulator guide capture and unavailable emulator earpiece routes are reported as explicit skips; they still require physical acceptance.

## Build

```bash
xcodebuild -project iOS/GetOverHere.xcodeproj \
  -scheme GetOverHere \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

cd Android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug
```

## License

Personal project. Not licensed for redistribution.
