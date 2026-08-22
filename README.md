# GetOverHere

Offline tour-guide broadcasting for iOS and Android. One guide speaks; guests listen and receive synchronized slides, a shared map target, or a sightline pointer. A tour uses a local Wi-Fi network and does not require Internet access, accounts, a backend, or analytics.

## Product

- One authenticated guide-to-many-guests audio session.
- Ordered local-image slide deck with automatic guest presentation.
- Offline PMTiles map with one guide-selected target pin.
- Device-local user dot, distance, and direction. Participant locations never leave their phones.
- Magnetic sightline pointer for landmarks that are not map coordinates.
- Late-join and reconnect recovery for presentation, pin, pointer, and cached assets.
- Receiver/headset playback by default to prevent acoustic feedback; speaker is an explicit override.

The authoritative requirements and acceptance gates are in [TourGuideProductSpec.md](TourGuideProductSpec.md). Architecture decisions are in [ADR.md](ADR.md), and executed evidence is in [ExperimentLog.md](ExperimentLog.md).

## Live architecture

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

Bonjour on iOS and NSD on Android discover guide sessions. Possession of a random per-tour short code is required before any lane admits a guest. Control and assets cannot block audio because each has an independent authenticated connection. Slide and map assets are content-addressed, chunked, resumable, and SHA-256 verified.

The operator currently provides the local network, normally with a pocket access point. Native Wi-Fi Aware is isolated behind a diagnostic lab and is not a production dependency. The app does not implement mesh routing.

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

cd Android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew connectedDebugAndroidTest
```

The first command tests Swift and Kotlin protocol parity, exact wire bytes, authentication, participant churn at 1/8/20/50 guests, fault accounting, Android JVM integration/APK assembly, and the iOS Simulator suite.

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
