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

Bonjour on iOS and NSD on Android discover LAN guide sessions. The `Bluetooth room discovery` toggle enables a foreground-only preview, without prompting at launch. Browsers scan, guides advertise, and joined LAN guests stop Bluetooth discovery. Physical Wi-Fi-off validation remains pending; Bluetooth-only rooms show that audio is unavailable and cannot yet join. Rooms start open, with optional guide-editable code locking; admission supplies a separate hidden media credential. Control and assets cannot block audio because each has an independent authenticated connection. Slide and map assets are content-addressed, chunked, resumable, and SHA-256 verified.

The current production path needs an existing local LAN. Native Wi-Fi Aware is isolated behind a diagnostic lab and is not yet a production dependency.

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
