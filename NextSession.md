# Next Session: Clean-Room Rewrite — BLE Control Plane + WiFi Audio

## What We Did This Session

Built a cross-platform P2P megaphone app (iOS: GetOverHere, Android: ComeOverHere). Went through multiple architecture iterations:

1. **v1**: Full chat/file/walkie-talkie with MultipeerConnectivity (iOS only)
2. **v2**: Added BLE transport for cross-platform, complex bridge/relay system
3. **v3**: Stripped to audio-only megaphone, simplified channel model
4. **v4**: Fixed wire format (Swift `_0` Codable issue), chunk framing overlap, GATT notification path
5. **v5**: Added L2CAP for audio — PSM sharing broken due to GATT operation sequencing
6. **CONCLUSION**: BLE GATT is unreliable for data transfer. BLE L2CAP PSM sharing fails. BLE bandwidth (~13 KB/s practical) can't handle audio (64 KB/s). Classic BT blocked on iOS for third-party apps.

### Key Decision Made (end of session):
**New architecture agreed with user:**
- BLE = control plane (discovery, RAFT leader election, commands, credential exchange)
- MultipeerConnectivity = iOS↔iOS data plane (when no Android present)
- WiFi Hotspot + UDP = cross-platform data plane (when Android detected)
- Android creates hotspot automatically via `startLocalOnlyHotspot()`
- iOS joins via `NEHotspotConfigurationManager`
- Audio over UDP multicast on the shared WiFi network

## Current State

### iOS Project
- **Path**: `/Users/aessam/tmp/ios-macos-apps/GetOverHere`
- **Branch**: `main`
- **Bundle ID**: `com.aens.GetOverHere`
- **Build**: `xcodebuild build -scheme GetOverHere -destination 'generic/platform=iOS Simulator'`
- **State**: Megaphone works iOS↔iOS via Multipeer. BLE discovery works cross-platform. Audio over BLE does NOT work (bandwidth limit). L2CAP added but PSM sharing broken. Code is messy from many patches.

### Android Project
- **Path**: `/Users/aessam/AndroidStudioProjects/ComeOverHere`
- **Branch**: `main`
- **Build**: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug`
- **State**: BLE transport works for discovery. Audio over BLE doesn't work. L2CAP added but untested due to PSM issue.

### TestFlight
- App exists in App Store Connect as `com.aens.GetOverHere`
- One build uploaded. User has icons handled.

## What's Next: CLEAN-ROOM REWRITE

**This is a rewrite, not a patch.** The existing BLE transport code is too tangled. Build the new architecture clean.

### Architecture:

```
┌─────────────────────────────────────────────┐
│                BLE Control Plane             │
│  (always on, both platforms, lightweight)    │
│                                              │
│  • Device discovery (scan + advertise)       │
│  • RAFT leader election                      │
│  • "Become WiFi host" command                │
│  • SSID + password credential exchange       │
│  • Channel announce/metadata                 │
│  • Heartbeat / keepalive                     │
└──────────┬────────────────────┬──────────────┘
           │                    │
   iOS only │                    │ Cross-platform
           │                    │
┌──────────▼──────────┐  ┌─────▼──────────────┐
│  MultipeerConnectivity│  │  WiFi Hotspot + UDP │
│  (iOS ↔ iOS)         │  │  (iOS ↔ Android)    │
│                      │  │                     │
│  • Audio streaming   │  │  • Android creates  │
│  • Auto WiFi Direct  │  │    hotspot (auto)   │
│  • Zero config       │  │  • iOS joins (auto) │
│  • Proven reliable   │  │  • UDP multicast    │
│                      │  │  • Audio streaming  │
└──────────────────────┘  └─────────────────────┘
```

### Implementation Plan (ordered):

#### Phase 0: Clean Up
```bash
# Keep the existing megaphone UI (ChannelRootView, ChannelSidebar, ChannelDetailView)
# Keep AudioEngine (capture + playback)
# Keep Channel + ChannelMessage models
# DELETE: BLETransport.swift (too tangled, rewrite from scratch)
# DELETE: L2CAPAudioStream.swift
# DELETE: DualTransport (CompositeTransport.swift)
# DELETE: MultipeerTransport.swift (rewrite simpler version)
# REWRITE: ChannelService.swift (clean transport abstraction)
```

#### Phase 1: BLE Control Plane (both platforms)
New file: `BLEControlPlane.swift` / `BLEControlPlane.kt`
- Scan + advertise with service UUID
- Exchange peer info (name, platform: "ios"/"android", capabilities)
- Send/receive JSON commands over single GATT write characteristic
- Commands: `channel_announce`, `become_wifi_host`, `wifi_credentials`, `heartbeat`
- NO audio over BLE. ONLY metadata.
- Simple, robust, one characteristic for writes, one for notifications

#### Phase 2: RAFT Leader Election (both platforms)
New file: `RAFTElection.swift` / `RAFTElection.kt`
- Simplified RAFT for leader election among BLE-connected peers
- Leader = the device that will coordinate the megaphone network
- When Android is present, prefer Android as WiFi host (since iOS can't create hotspot programmatically)
- Leader broadcasts heartbeat; if missed, re-election

#### Phase 3: WiFi Hotspot Transport (Android creates, iOS joins)
New files:
- Android: `WiFiHotspotManager.kt` — `startLocalOnlyHotspot()`, returns SSID + password
- iOS: `WiFiHotspotJoiner.swift` — `NEHotspotConfigurationManager.apply()` with SSID + password
- Both: `UDPAudioTransport.swift` / `UDPAudioTransport.kt` — UDP multicast send/receive

Flow:
1. BLE detects Android device
2. Leader election → Android becomes WiFi host
3. Android calls `startLocalOnlyHotspot()` → gets SSID + password
4. Android sends `wifi_credentials` command via BLE to all peers
5. iOS receives credentials → joins hotspot via `NEHotspotConfigurationManager`
6. Both open UDP multicast socket on the hotspot network
7. Audio streams over UDP — megabits of bandwidth

#### Phase 4: MultipeerConnectivity Transport (iOS-only fast path)
New file: `MultipeerTransport.swift` (simplified from current)
- Auto-discover + auto-connect (current logic, cleaned up)
- Used when ALL peers are iOS (no Android detected via BLE)
- Fallback: if WiFi hotspot is active, Multipeer can coexist

#### Phase 5: Unified ChannelService
New file: `ChannelService.swift` (rewritten)
- Protocol-based transport abstraction
- Megaphone model: one creator (speaker), everyone listens
- Channel announce via BLE control plane
- Audio via active transport (Multipeer OR UDP, transparent to service)
- Periodic re-announce via BLE

#### Phase 6: Wire it up + test
- Update AppCoordinator / MainActivity
- Build both platforms
- Test: iOS↔iOS (Multipeer), iOS↔Android (WiFi hotspot + UDP)

### Key APIs:

**Android WiFi Hotspot:**
```kotlin
val wifiManager = getSystemService(WIFI_SERVICE) as WifiManager
wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalHotspotCallback() {
    override fun onStarted(reservation: WifiManager.LocalHotspotReservation) {
        val config = reservation.wifiConfiguration
        // OR for Android 13+: reservation.softApConfiguration
        val ssid = config.SSID  // or softApConfiguration.ssid
        val password = config.preSharedKey  // or softApConfiguration.passphrase
        // Share via BLE to all peers
    }
}, null)
```

**iOS Join Hotspot:**
```swift
import NetworkExtension
let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
NEHotspotConfigurationManager.shared.apply(config) { error in
    if let error { /* handle */ }
    // Connected to hotspot. Open UDP socket.
}
```

**UDP Multicast (both):**
```
// Multicast group: 239.0.0.1, port: 50000
// Send: audio packets to multicast group
// Receive: listen on multicast group
// Packet format: [channelID 36 bytes][audio float32 PCM]
```

### Commands to start:
```bash
# iOS
cd /Users/aessam/tmp/ios-macos-apps/GetOverHere

# Android
cd /Users/aessam/AndroidStudioProjects/ComeOverHere
```

## Decisions Made

1. **BLE = control plane ONLY** — no audio, no large data over BLE ever
2. **Android = WiFi host** when cross-platform is needed (iOS can't create hotspot programmatically)
3. **UDP multicast** for audio on WiFi hotspot (simple, broadcast-friendly, low latency)
4. **Multipeer stays** for iOS-only mode (proven, fast, zero config)
5. **Clean rewrite** — don't patch existing BLE transport, start fresh

## Decisions Pending

1. **RAFT implementation complexity**: Full RAFT or simplified leader election? (Suggest simplified — just term numbers + heartbeat, no log replication needed)
2. **What if leader is iOS?**: iOS can't create hotspot automatically. Options: (a) always prefer Android as host, (b) ask iOS user to enable Personal Hotspot manually, (c) fall back to BLE-only metadata + Multipeer audio for iOS-only groups
3. **`startLocalOnlyHotspot` vs `startTethering`**: Local-only doesn't provide internet. Is that OK? (Yes — we don't need internet, just a local network for UDP)
4. **Audio format**: Keep 16kHz mono float32 (64 KB/s)? Or upgrade to higher quality since WiFi has unlimited bandwidth?

## Gotchas

1. **`NEHotspotConfigurationManager` requires entitlement**: Add `com.apple.developer.networking.HotspotConfiguration` to the iOS app's entitlements
2. **`startLocalOnlyHotspot` deprecated in Android 13+**: Use `startLocalOnlyHotspot(SoftApConfiguration, ...)` for API 33+
3. **iOS can't create WiFi hotspot programmatically** — if all devices are iOS, stick with Multipeer. Only go WiFi when Android is present.
4. **UDP multicast on Android hotspot**: The local-only hotspot might not enable multicast by default. Test with `MulticastLock`.
5. **Don't generate icons with scripts** — user handles manually
6. **Don't replace working transports** — Multipeer stays for iOS↔iOS
7. **Swift Codable `_0` wrapper** — use custom Codable for any cross-platform JSON
8. **Test with real devices** — BLE + WiFi hotspot don't work in simulators

## Nothing Running That Costs Money

No cloud resources. All local + TestFlight (free).
