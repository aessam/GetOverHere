# Next Session: L2CAP Audio Streaming

## What We Did This Session

Built a cross-platform P2P megaphone app from scratch — iOS (GetOverHere) and Android (ComeOverHere). One speaker per channel, everyone else listens. No WiFi/cellular needed.

### Journey:
1. Started with iOS-only: Multipeer Connectivity for chat, file sharing, walkie-talkie
2. Added Android with BLE transport + Nearby Connections
3. Attempted BLE bridge for cross-platform — many reliability issues
4. Stripped to audio-only megaphone (dramatically simpler)
5. Fixed wire format mismatch (Swift Codable `_0` wrapper vs Android manual JSON)
6. Fixed BLE chunk framing protocol (byte overlap between DataTag and ChunkFlags)
7. Added BLE notifications for bidirectional data (central writes + peripheral notifications)
8. **Hit BLE bandwidth wall**: GATT can only do ~13 KB/s, audio needs 64 KB/s

### Current Architecture:
- **iOS↔iOS**: MultipeerTransport (WiFi Direct/AWDL) — audio works perfectly
- **Cross-platform discovery**: BLE GATT — channels visible both ways ✅
- **Cross-platform audio**: BLE GATT notifications — **NOT WORKING** (bandwidth insufficient)

## Current State

### iOS Project
- **Path**: `/Users/aessam/tmp/ios-macos-apps/GetOverHere`
- **Branch**: `main` (latest commit has megaphone rewrite + BLE fixes)
- **Bundle ID**: `com.aens.GetOverHere`
- **Team ID**: `VW9YC3A6JM`
- **Build**: `xcodebuild build -scheme GetOverHere -destination 'generic/platform=iOS Simulator'`
- **TestFlight**: App exists in App Store Connect, first build uploaded
- **Key files**:
  - `Core/DualTransport.swift` — runs Multipeer + BLE simultaneously (was CompositeTransport)
  - `Core/BLETransport.swift` — GATT server + client, notify characteristic added
  - `Core/MultipeerTransport.swift` — auto-invite with tiebreaker, unique MCPeerID
  - `Services/ChannelService.swift` — audio-only megaphone, creator-speaks, periodic broadcast
  - `Services/AudioEngine.swift` — AVAudioEngine, converter 48kHz→16kHz, noise gate
  - `Views/ChannelRootView.swift` + `ChannelSidebar.swift` + `ChannelDetailView.swift`

### Android Project
- **Path**: `/Users/aessam/AndroidStudioProjects/ComeOverHere`
- **Branch**: `main`
- **Build**: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug`
- **Key files**:
  - `core/BLETransport.kt` — GATT server + client, no scan filter (checks UUID in code)
  - `core/TransportMessage.kt` — manual JSON with `unwrap0()` for Swift Codable compat
  - `service/ChannelService.kt` — mirrors iOS megaphone logic
  - `service/AudioEngine.kt` — AudioRecord/AudioTrack at 16kHz mono float32
  - `ui/ChannelScreen.kt` + `ui/AppViewModel.kt`

### Wire Format (cross-platform)
- **BLE framing**: `[ChunkFlag 1 byte][DataTag 1 byte][payload]`
  - ChunkFlags: 0x00=continuation, 0x01=first, 0x02=last, 0x03=single
  - DataTags: 0x01=message, 0x02=audio
  - ⚠️ 0x01 and 0x02 overlap between flags and tags — only works because chunked data always starts with flag
- **Messages**: JSON matching Swift Codable (Android uses `unwrap0()` for `_0` key)
- **Audio**: `[DataTag.audio][channelID 36 bytes UTF-8][float32 PCM data]`
- **Channel announce**: `{"channelAnnounce": {"channelID":"...", "channelName":"...", "createdAt":..., "createdBy":"..."}}`
- **Dates**: Swift reference epoch (seconds since Jan 1 2001). Android converts via `SWIFT_REFERENCE_EPOCH = 978307200`

### BLE UUIDs (both platforms)
```
Service:     A1B2C3D4-0001-0000-0000-000000000000
Data Write:  A1B2C3D4-0002-0000-0000-000000000000
Data Notify: A1B2C3D4-0003-0000-0000-000000000000
Peer Name:   A1B2C3D4-0004-0000-0000-000000000000
```

## What's Next: L2CAP Audio Streaming

The user approved adding BLE L2CAP channels for audio. This is the focused next task.

### Plan:
1. **iOS: Add L2CAP listener + publisher**
   - `CBPeripheralManager.publishL2CAPChannel(withEncryption:)` — host opens L2CAP PSM
   - Include PSM in channel announce or peer name characteristic
   - When broadcasting: write audio to L2CAP output stream
   - When listening: read audio from L2CAP input stream
   - Keep GATT for discovery/metadata, L2CAP only for audio

2. **Android: Add L2CAP client + server**
   - `BluetoothDevice.createL2capChannel(psm)` or `BluetoothServerSocket.createL2capChannel()`
   - Connect to iOS's L2CAP PSM after GATT handshake
   - Read/write audio via `InputStream`/`OutputStream`

3. **Protocol**:
   - After GATT connection + peer name exchange, the creator's device opens L2CAP
   - PSM (Protocol/Service Multiplexer) number shared via a new GATT characteristic or in the channel announce
   - Listeners connect to the L2CAP channel
   - Audio flows as raw `[channelID 36 bytes][float32 PCM]` over the L2CAP stream
   - No chunk framing needed — L2CAP is stream-oriented

4. **Bandwidth**: L2CAP over BLE can do 100+ KB/s. Audio at 64 KB/s should work.

5. **Fallback**: Keep GATT notification path for devices that don't support L2CAP (shouldn't be needed since both iOS 11+ and Android 10+ support it)

### Commands to resume:
```bash
# iOS
cd /Users/aessam/tmp/ios-macos-apps/GetOverHere
xcodebuild build -scheme GetOverHere -destination 'generic/platform=iOS Simulator' -quiet

# Android
cd /Users/aessam/AndroidStudioProjects/ComeOverHere
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug

# TestFlight (after archive)
xcodebuild archive -scheme GetOverHere -destination 'generic/platform=iOS' -archivePath /tmp/GetOverHere.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath /tmp/GetOverHere.xcarchive -exportOptionsPlist /tmp/ExportOptions.plist -allowProvisioningUpdates
```

## Decisions Pending

1. **L2CAP PSM sharing**: Via new GATT characteristic? Or embedded in channel announce JSON? (GATT characteristic is cleaner — PSM is a transport detail, not a channel property)
2. **Audio format for L2CAP**: Keep 16kHz float32 (64 KB/s)? Or switch to 16kHz int16 (32 KB/s) for margin?
3. **Multipeer iOS-to-iOS**: Still the primary for iOS mesh? Or switch everything to L2CAP for consistency?

## Gotchas

1. **iOS central BLE connection often fails** — `didConnect` never fires. The peripheral-side notification path works around this but it's fragile. L2CAP might have the same issue if initiated from the central side.
2. **ChunkFlag/DataTag byte overlap** (0x01, 0x02) — works now but is fragile. Consider changing chunk flags to 0xF0-0xF3 in the next refactor.
3. **`Audio session config failed: OSStatus error -50`** on iOS — happens when switching from capture to playback. Doesn't crash but playback may not start. Needs investigation.
4. **Swift Codable `_0` wrapper** — custom Codable on `TransportMessage` fixes this for BLE. Multipeer between iOS devices uses the same encoder so it works there too.
5. **Don't generate app icons with scripts** — user handles icons manually.
6. **Don't replace working transports** — Multipeer stays for iOS↔iOS. Add L2CAP alongside, don't replace.
7. **Android scan has no UUID filter** — scans all BLE, checks UUID in code. Works but burns more battery.
8. **Periodic channel broadcast every 5 seconds** on both platforms — essential for late-joining peers.

## Nothing Running That Costs Money

No cloud resources, no GPUs, no paid services. Everything is local + TestFlight (free tier).
