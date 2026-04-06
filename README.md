# GET OVER HERE!

> *"GET OVER HERE!"* — Scorpion, Mortal Kombat

A peer-to-peer megaphone app that yanks nearby devices into a live audio channel — no backend, no accounts, no excuses. One person speaks, everyone listens. Like Scorpion's spear, it reaches out and pulls you in.

## What It Does

Create a channel. Speak. Every nearby device hears you — **instantly**, over the local network or via Android WiFi hotspot. No sign-ups, no cloud. Just raw, direct audio between devices.

- **One speaker per channel** — the creator holds the mic
- **Everyone else listens** — join and hear, that's it
- **Cross-platform** — iOS and Android, side by side
- **Zero infrastructure** — works on any shared network, or via Android hotspot when there's nothing else

## How It Works

```
  [Speaker]                    [Listener]
     |                             |
     |── BLE / Bonjour discover ──>|
     |                             |
     |── channel announce ────────>|
     |                             |
     |══ TCP audio stream ════════>|
     |   (16kHz mono float32)      |
```

Three-tier architecture:

| Layer | Purpose | Tech |
|-------|---------|------|
| **Control Plane** | Discovery + coordination | BLE GATT / Bonjour |
| **Leader Election** | Picks WiFi host (Android preferred) | Simplified RAFT |
| **Audio Plane** | Actual audio streaming | TCP (cross-platform) / MultipeerConnectivity (iOS-only) |

When Android is present, it spins up a local WiFi hotspot. iOS joins automatically and discovers the gateway IP (= Android). Audio flows over TCP with length-prefixed PCM packets. When it's iOS-only, MultipeerConnectivity handles everything.

## Project Structure

```
GetOverHere/
  iOS/                          # Xcode project (Swift, iOS 17+)
    GetOverHere/
      Core/
        BLEControlPlane.swift       # BLE GATT server+client for cross-platform discovery
        LocalControlPlane.swift     # Bonjour-based discovery for same-network
        LeaderElection.swift        # RAFT-inspired leader election
        NetworkCoordinator.swift    # Orchestrates control + audio plane selection
        UDPAudioPlane.swift         # TCP audio server/client
        MultipeerAudioPlane.swift   # iOS-only audio via MultipeerConnectivity
        WiFiHotspotJoiner.swift     # Joins Android hotspot + gateway IP discovery
      Services/
        AudioEngine.swift           # AVAudioEngine capture/playback + format conversion
        ChannelService.swift        # Megaphone channel lifecycle
      Models/
        Channel.swift
      Views/
        ChannelRootView.swift       # Main UI
        ChannelSidebar.swift        # Channel list
        ChannelDetailView.swift     # Active channel view
      Navigation/
        AppCoordinator.swift        # App lifecycle coordinator
    GetOverHere.xcodeproj/
  Android/                      # Gradle project (Kotlin, API 26+)
    app/src/main/java/com/aessam/comeoverhere/
      core/
        BLEControlPlane.kt         # BLE GATT for cross-platform discovery
        TransportProtocol.kt       # Shared protocol types + JSON serialization
        LeaderElection.kt          # RAFT leader election
        NetworkCoordinator.kt      # Hotspot + audio plane coordination
        UDPAudioPlane.kt           # TCP audio server/client
        WiFiHotspotManager.kt      # startLocalOnlyHotspot wrapper
      service/
        ChannelService.kt          # Megaphone channel lifecycle
        AudioEngine.kt             # AudioRecord/AudioTrack capture/playback
      ui/
        ChannelScreen.kt           # Compose UI
        AppViewModel.kt
  ADR.md                        # Architecture decisions
  LessonsLearned.md             # What went wrong and why
  DESIGN.md                     # UI/UX design (superseded — see below)
  SPEC.md                       # Original spec (superseded — see below)
```

## Requirements

| Platform | Min Version | Language |
|----------|-------------|----------|
| iOS | 17+ | Swift 5.9+ |
| Android | API 26 (8.0+) | Kotlin |

## Building

**iOS**: Open `iOS/GetOverHere.xcodeproj` in Xcode 16+. Build and run on device (simulator lacks BLE/Multipeer).

**Android**: Open `Android/` in Android Studio. `./gradlew assembleDebug`.

## The Name

Scorpion doesn't ask politely. He throws a spear, hooks you, and drags you over. This app does the same thing with audio — no setup, no negotiation. You create a channel, and nearby devices get pulled in.

**GET OVER HERE!**

## License

Personal project. Not licensed for redistribution.
