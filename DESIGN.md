# GetOverHere / ComeOverHere — Design

**Version:** 2.0 (Megaphone rewrite)
**Date:** 2026-04-05
**Supersedes:** v1.0 (channel-based chat/files/walkie-talkie)

---

## 1. Product

One-way audio broadcast. Creator speaks, everyone else listens. No text, no files, no floor control. A megaphone.

## 2. Screen Architecture

### 2.1 Single View

The app is one screen: **channel list + channel detail**. No tabs, no settings, no onboarding.

### 2.2 Layout by Platform

| Platform | Channel List | Channel Detail |
|----------|-------------|----------------|
| **iPhone** | Sheet/sidebar, swipe from left | Full screen |
| **iPad** | Persistent sidebar | Detail pane |
| **Android Phone** | Navigation drawer | Full screen |
| **Android Tablet** | Persistent drawer | Detail pane |

### 2.3 iOS View Hierarchy

```
ChannelRootView
├── ChannelSidebar
│   ├── ChannelRow[] (discovered channels)
│   └── CreateChannelButton (+)
└── ChannelDetailView
    ├── Channel name + listener count
    ├── Audio quality selector (Standard / HD)
    ├── State indicator:
    │   ├── IDLE: "Create or join a channel"
    │   ├── BROADCASTING: waveform + "You are speaking"
    │   └── LISTENING: waveform + "Listening to [creator]"
    └── Leave button
```

### 2.4 Android View Hierarchy

```
Scaffold
├── TopAppBar (channel name, hamburger)
├── ModalNavigationDrawer
│   ├── ChannelRow[] (discovered channels)
│   └── CreateChannelFAB
└── ChannelContent
    ├── Audio quality selector
    ├── State indicator (same states as iOS)
    └── Leave button
```

## 3. Channel Model

```
Channel {
  id:          String (UUID)
  name:        String (1-32 chars)
  createdAt:   Date
  createdBy:   String (peer ID of creator)
  audioHostIP: String? (speaker's TCP server IP)
}
```

### Rules

- Creator is the ONLY speaker. Everyone else is a listener.
- Channel ends when creator leaves.
- Channels are discovered via BLE control plane / Bonjour.
- Channel announces repeat every 5 seconds for late joiners.

## 4. Audio

### 4.1 Wire Format

| Quality | Sample Rate | Channels | Format | Bandwidth |
|---------|-------------|----------|--------|-----------|
| Standard | 16 kHz | Mono | Float32 | ~64 KB/s |
| HD | 44.1 kHz | Stereo | Float32 | ~353 KB/s |

TCP packets: `[4 bytes big-endian length][PCM data]`

### 4.2 Audio Engine (iOS)

- `AVAudioEngine` with input tap for capture
- `AVAudioConverter` for hardware format → wire format
- `AVAudioPlayerNode` for playback
- `.playAndRecord` category with `.defaultToSpeaker`
- Earpiece toggle for listeners near the speaker

### 4.3 Audio Engine (Android)

- `AudioRecord` for capture (16kHz mono float32)
- `AudioTrack` for playback
- AEC + noise suppressor enabled

## 5. Network Architecture

### 5.1 Three Tiers

```
┌─────────────────────────────────┐
│        Control Plane            │  BLE GATT / Bonjour
│  Discovery, commands, metadata  │  ~1 KB/s
├─────────────────────────────────┤
│       Leader Election           │  Simplified RAFT
│  Picks WiFi host (Android)     │  Heartbeat every 2s
├─────────────────────────────────┤
│         Audio Plane             │  TCP / MultipeerConnectivity
│  PCM audio streaming            │  64-353 KB/s
└─────────────────────────────────┘
```

### 5.2 Control Plane

**BLE (cross-platform, no infrastructure)**:
- GATT service `A1B2C3D4-0001-...`
- Characteristics: commandWrite, commandNotify, peerInfo
- JSON commands over GATT writes/notifications
- MTU 512 negotiated before commands

**Bonjour (same-network)**:
- Service type `_goh-audio._tcp`
- Zero-config mDNS discovery
- Used when devices are already on the same WiFi

### 5.3 BLE Commands (JSON wire format)

```json
{"channelAnnounce": {"channelID":"...", "channelName":"...", "createdBy":"...", "audioQuality":"standard", "wifiSSID":null, "audioHostIP":"10.0.0.105"}}
{"channelEnded": {"channelID":"..."}}
{"wifiCredentials": {"ssid":"AndroidShare_1234", "password":"abc123", "hostIP":null}}
{"heartbeat": {"term":1, "leaderID":"..."}}
{"voteRequest": {"term":1, "candidateID":"..."}}
{"voteResponse": {"term":1, "granted":true}}
{"becomeWiFiHost": true}
```

### 5.4 Audio Plane Selection

```
if Android present AND WiFi hotspot active:
    → TCP audio (UDPAudioPlane — name is legacy)
else if same network (Bonjour):
    → TCP audio
else:
    → MultipeerConnectivity (iOS-only)
```

### 5.5 Cross-Platform Flow

```
1. BLE discovers peers
2. RAFT elects Android as leader
3. Android starts WiFi hotspot (startLocalOnlyHotspot)
4. Android shares credentials via BLE (wifiCredentials command)
5. iOS joins hotspot (NEHotspotConfigurationManager)
6. iOS discovers gateway IP via getifaddrs (gateway = Android)
7. Speaker creates channel → starts TCP server on 0.0.0.0:50000
8. Listener joins channel → connects TCP client to speaker's IP:50000
9. Audio streams as length-prefixed PCM packets
```

### 5.6 IP Discovery

| Direction | How listener finds speaker |
|-----------|--------------------------|
| iOS listens to Android | Gateway IP from `getifaddrs` after joining hotspot |
| Android listens to iOS | `audioHostIP` from channelAnnounce (iOS's WiFi IP) |
| Same network | Speaker IP from Bonjour/channelAnnounce |

## 6. Platform-Specific Notes

### iOS
- Entitlement: `com.apple.developer.networking.HotspotConfiguration`
- Info.plist: NSBonjourServices, NSBluetoothAlwaysUsageDescription, NSMicrophoneUsageDescription, NSLocalNetworkUsageDescription
- Audio session: `.playAndRecord` mode `.voiceChat`

### Android
- Permissions: BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE, RECORD_AUDIO, ACCESS_FINE_LOCATION, NEARBY_WIFI_DEVICES
- Hotspot: `WifiManager.startLocalOnlyHotspot()` (API 26+)
- Audio: `AudioRecord` + `AudioTrack` on background threads
