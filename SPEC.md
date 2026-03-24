# GetOverHere / ComeOverHere — Channel-Based P2P Spec

**Version:** 1.0
**Date:** 2026-03-23
**Status:** Active

---

## 1. Product Vision

One view. Channels. Broadcast everything. No routing complexity.

Replace the current tab-based UI (Nearby, Chats, Files, Walkie-Talkie) with a **single channel view** modeled after Discord channels over P2P mesh. Every device sees every channel. Every message is broadcast to all connected peers. Filtering happens client-side by `channelID`.

### Core Principles

1. **Broadcast, don't route.** All messages go to all connected peers. No point-to-point. No peer selection.
2. **One view.** Channel list sidebar + active channel content. No tabs.
3. **Channels unify everything.** Text, files/photos, and walkie-talkie PTT all live inside a channel.
4. **Bridge relays everything.** One iOS device bridges Multipeer mesh ↔ BLE mesh. All message types relay.
5. **Townsquare is always there.** Default channel, cannot be deleted, auto-joined on connect.

---

## 2. Channel Model

### 2.1 Channel Definition

```
Channel {
  id:        String (UUID)        // Unique across the mesh
  name:      String               // Human-readable, 1-32 chars
  createdAt: Double               // Swift reference date (seconds since 2001-01-01)
  createdBy: String               // senderID of creator
}
```

### 2.2 Townsquare

- **ID:** `"00000000-0000-0000-0000-000000000000"` (well-known, hardcoded on both platforms)
- **Name:** `"Townsquare"`
- **Behavior:**
  - Created locally on app launch if not present
  - Cannot be deleted or renamed
  - Auto-selected as active channel on first launch
  - All peers auto-join Townsquare on connection

### 2.3 Channel Lifecycle

| Action | Trigger | Broadcast |
|--------|---------|-----------|
| Create | User taps "+" | `channelAnnounce` to all peers |
| Join | User taps channel / auto on connect (Townsquare) | `channelAnnounce` to all peers |
| Leave | User leaves channel | Nothing (local only) |
| Discover | Receive `channelAnnounce` | Add to local channel list |
| Sync | On new peer connect | Send `channelAnnounce` for all locally known channels |

**No delete.** Channels are never deleted over the wire. A device may locally hide empty channels, but never sends a delete message. This avoids split-brain on who owns a channel.

### 2.4 Channel Sync Protocol

When a new peer connects:
1. Each device sends a `channelAnnounce` for every channel it knows about
2. Receiver upserts: if channel ID already known, ignore; if new, add to local list
3. This is idempotent — duplicates are harmless

---

## 3. Wire Format

### 3.1 Transport Framing (unchanged)

Over Multipeer and BLE, the existing framing is preserved:

```
[DataTag: 1 byte] [Payload: N bytes]

DataTag:
  0x01 = JSON message (TransportMessage)
  0x02 = Audio data (raw PCM)
```

BLE chunking (first-byte flags 0x00/0x01/0x02/0x03) remains unchanged.

### 3.2 TransportMessage Envelope

All JSON messages use the existing discriminated-union encoding where the top-level key is the case name.

**Updated enum cases:**

```
TransportMessage:
  | text(TextPayload)
  | walkieTalkieControl(WalkieTalkieControl)
  | channelAnnounce(ChannelAnnounce)       // NEW
  | fileHeader(FileHeader)                  // NEW
  | fileChunk(FileChunk)                    // NEW
```

### 3.3 TextPayload (updated)

```
TextPayload {
  id:         String  // UUID, dedup key
  channelID:  String  // UUID of target channel
  senderID:   String  // Stable peer ID
  senderName: String  // Display name
  content:    String  // Message text (may be empty if attachment-only)
  timestamp:  Double  // Swift reference date
  replyTo:    String? // Optional: ID of message being replied to
}
```

**Change from current:** Added `channelID` (required) and `replyTo` (optional). Removed peer-to-peer semantics — messages are always broadcast.

### 3.4 WalkieTalkieControl (updated)

```
WalkieTalkieControl:
  | requestFloor  { channelID, peerID, peerName }
  | grantFloor    { channelID, peerID }
  | releaseFloor  { channelID, peerID }
  | denyFloor     { channelID, reason }
```

**Removed:** `joinChannel` and `leaveChannel` (replaced by `channelAnnounce`).

Floor control is per-channel. A device only processes floor control for its `activeChannelID`.

### 3.5 ChannelAnnounce (new)

```
ChannelAnnounce {
  channelID:   String  // UUID
  channelName: String  // Display name
  createdAt:   Double  // Swift reference date
  createdBy:   String  // senderID of original creator
}
```

**JSON example:**
```json
{
  "channelAnnounce": {
    "channelID": "A1B2C3D4-...",
    "channelName": "Photos",
    "createdAt": 796348800.0,
    "createdBy": "peer-uuid-..."
  }
}
```

This is idempotent. Receiving the same channelID twice is a no-op.

### 3.6 FileHeader (new)

```
FileHeader {
  transferID: String  // UUID, groups header + chunks
  channelID:  String  // Target channel
  senderID:   String
  senderName: String
  fileName:   String  // Original filename with extension
  fileSize:   Int     // Total bytes
  mimeType:   String  // e.g., "image/jpeg", "application/pdf"
  timestamp:  Double
}
```

### 3.7 FileChunk (new)

```
FileChunk {
  transferID: String  // Matches FileHeader.transferID
  index:      Int     // 0-based chunk sequence number
  totalChunks: Int    // Total expected chunks
  data:       String  // Base64-encoded chunk data
}
```

**Chunk size:** 16 KB raw (before base64). This fits within BLE MTU after chunking and keeps Multipeer messages small.

**File transfer flow:**
1. Sender broadcasts `fileHeader` to all peers
2. Sender broadcasts `fileChunk` messages sequentially (index 0, 1, 2, ...)
3. Receiver collects chunks by `transferID`, reassembles when `index == totalChunks - 1` received
4. Receiver writes to local storage, displays inline in channel

**Why not Multipeer's sendResource?** It's point-to-point. Broadcast semantics require chunked JSON so the bridge can relay file data to BLE peers too.

### 3.8 Audio Data (unchanged wire format)

```
DataTag 0x02 + raw PCM data
```

**Format:** 16 kHz, mono, float32, little-endian (~64 KB/s)

**New requirement:** Audio frames MUST include a 36-byte header prepended to the PCM data:

```
AudioFrame {
  channelID: [16 bytes]  // UUID as raw bytes (big-endian)
  senderID:  [16 bytes]  // UUID as raw bytes (big-endian)
  seqNum:    [4 bytes]   // uint32, big-endian, monotonically increasing per sender
  pcmData:   [N bytes]   // float32 PCM samples
}
```

This allows receivers to filter audio by channel and detect gaps. The overhead is 36 bytes per frame (~900 bytes/sec at 25fps), negligible vs PCM data.

---

## 4. Relay / Bridge Protocol

### 4.1 Bridge Mode

One iOS device enables bridge mode. This device runs both Multipeer (iOS mesh) and BLE (Android mesh) simultaneously.

**Bridge behavior:**
- Every `TransportMessage` (text, control, channelAnnounce, fileHeader, fileChunk) received on one transport is re-sent on the other
- Every audio frame received on one transport is re-sent on the other
- **Dedup:** Bridge tracks `messageID` (for text), `transferID+index` (for file chunks), and `channelID` (for announces) to prevent relay loops
- Audio is NOT deduped (stateless relay, lossy tolerance)

### 4.2 Dedup Strategy

```
seenMessages: Set<String>        // TextPayload.id
seenFileChunks: Set<String>      // "{transferID}:{index}"
seenChannels: Set<String>        // channelAnnounce.channelID (only dedup announce, not content)
```

- Max set size: 10,000 entries per set. Evict oldest on overflow (FIFO).
- TTL: entries expire after 5 minutes (prevents unbounded growth).
- WalkieTalkieControl messages: dedup by `"{controlType}:{channelID}:{peerID}"`, TTL 2 seconds (floor state is short-lived).

### 4.3 Bridge Peer Visibility

- Peers from the BLE side appear in the Multipeer peers' channel member lists (and vice versa)
- The bridge device itself appears as a normal peer on both meshes
- Peer origin tracking (`peerOrigin` map) is internal to CompositeTransport — the UI doesn't distinguish iOS vs Android peers

---

## 5. UI Architecture

### 5.1 Single View Layout

```
+------------------------------------------+
|  GetOverHere           [Bridge] [+ Chan] |
+----------+-------------------------------+
| Channels | #Townsquare                   |
|          |-------------------------------|
| # Town-  | [Alice] Hey everyone!         |
|   square | [Bob] Check this out           |
| # Photos |   [photo_inline.jpg]          |
| # Road-  | [Charlie] 🎙 Speaking...       |
|   trip   |                               |
|          |-------------------------------|
|          | [Attach] [___message___] [Send]|
|          | [🎙 Push to Talk            ] |
+----------+-------------------------------+
| Nearby: 3 peers connected               |
+------------------------------------------+
```

### 5.2 View Hierarchy

```
ChannelRootView
├── ChannelSidebar (channel list, collapsible on iPhone)
│   ├── Townsquare (pinned, top)
│   ├── User-created channels (sorted by name)
│   └── "+ New Channel" button
├── ChannelContentView (active channel)
│   ├── ChannelHeader (name, member count, PTT indicator)
│   ├── MessageList (scrolling, bottom-anchored)
│   │   ├── TextBubble (sender, content, timestamp)
│   │   ├── FileBubble (thumbnail/icon, filename, progress)
│   │   └── AudioIndicator (🎙 "Alice is speaking...")
│   └── InputBar
│       ├── AttachButton (photo picker / file picker)
│       ├── TextField (message input)
│       ├── SendButton
│       └── PTTButton (push-to-talk, full-width below text input)
└── StatusBar (bottom)
    ├── Peer count ("3 peers connected")
    └── Bridge indicator (if bridge mode active)
```

### 5.3 iPhone vs iPad

- **iPhone:** Channel list is a sheet/drawer, swipe to reveal. Active channel fills screen.
- **iPad:** NavigationSplitView — sidebar always visible, detail shows active channel.

### 5.4 Interaction Details

**Channel switching:**
- Tap channel in sidebar → set `activeChannelID` → filter messages → scroll to bottom
- If PTT was active in previous channel, release floor first

**New channel:**
- Tap "+" → alert with text field → create channel → broadcast `channelAnnounce` → auto-switch to it

**Bridge toggle:**
- In status bar or settings. Tap to enable/disable BLE transport.
- Visual indicator when bridge is active (e.g., icon badge)

**Push-to-talk:**
- PTT button is always visible in InputBar for the active channel
- Press and hold → `requestFloor` → start audio capture → stream to all peers
- Release → `releaseFloor` → stop capture
- While someone else holds floor → PTT button disabled, show "🎙 {name} speaking"

**File/photo sharing:**
- Tap attach → photo picker or file browser
- Selected file → `fileHeader` + `fileChunk` sequence broadcast
- Inline preview for images (thumbnail in message list)
- Tap to open/share for other file types

**Message display:**
- Messages filtered by `activeChannelID`
- Grouped by sender for consecutive messages
- Timestamps shown every 5 minutes or on sender change
- File messages show inline (images) or as file cards (documents)

---

## 6. Data Model Changes

### 6.1 iOS (Swift)

**Replace ChatMessage with ChannelMessage (SwiftData):**

```swift
@Model
final class ChannelMessage {
    @Attribute(.unique) var id: String        // TextPayload.id or FileHeader.transferID
    var channelID: String                      // Channel UUID
    var senderID: String
    var senderName: String
    var content: String                        // Text content (empty for file-only)
    var timestamp: Date
    var isFromMe: Bool

    // File attachment (nil for text-only messages)
    var fileName: String?
    var fileSize: Int?
    var mimeType: String?
    var localFilePath: String?                 // Path after download complete

    var replyToID: String?                     // Optional reply reference
}
```

**Channel (in-memory, no persistence needed):**

```swift
struct Channel: Identifiable, Hashable {
    let id: String           // UUID string
    var name: String
    let createdAt: Date
    let createdBy: String

    static let townsquare = Channel(
        id: "00000000-0000-0000-0000-000000000000",
        name: "Townsquare",
        createdAt: .distantPast,
        createdBy: "system"
    )
}
```

### 6.2 Android (Kotlin)

**ChannelMessage (in-memory list, same fields):**

```kotlin
data class ChannelMessage(
    val id: String,
    val channelID: String,
    val senderID: String,
    val senderName: String,
    val content: String,
    val timestamp: Double,     // Swift reference date
    val isFromMe: Boolean,
    val fileName: String? = null,
    val fileSize: Int? = null,
    val mimeType: String? = null,
    val localFilePath: String? = null,
    val replyToID: String? = null
)
```

**Channel (same structure):**

```kotlin
data class Channel(
    val id: String,
    val name: String,
    val createdAt: Double,
    val createdBy: String
) {
    companion object {
        val TOWNSQUARE = Channel(
            id = "00000000-0000-0000-0000-000000000000",
            name = "Townsquare",
            createdAt = 0.0,
            createdBy = "system"
        )
    }
}
```

---

## 7. Service Architecture

### 7.1 ChannelService (replaces ChatService + WalkieTalkieService)

Single service that owns channel state, message history, floor control, and file transfers.

**State:**

```
channels: [Channel]                              // All known channels
activeChannelID: String                          // Currently viewed channel
messagesByChannel: [String: [ChannelMessage]]    // channelID → messages
floorStateByChannel: [String: FloorState]        // channelID → floor state
activeTransfers: [String: FileTransferState]     // transferID → progress
```

**Responsibilities:**
1. Listen to all `TransportMessage` types on the transport
2. Route `text` messages → append to `messagesByChannel[channelID]`, persist
3. Route `walkieTalkieControl` → update `floorStateByChannel[channelID]`
4. Route `channelAnnounce` → upsert `channels`
5. Route `fileHeader` → create transfer entry, display placeholder in channel
6. Route `fileChunk` → accumulate chunks, on completion write file + update message
7. Route audio frames → if `channelID == activeChannelID`, play audio
8. On new peer connect → broadcast all known `channelAnnounce` messages

### 7.2 AudioEngine (unchanged)

Same 16kHz mono float32 capture/playback. No changes to audio processing.

The only change: callers now prepend the 36-byte audio header (channelID + senderID + seqNum) before sending, and strip it on receive.

### 7.3 Transport Layer (minimal changes)

**TransportProtocol:** No interface changes. `send()` already takes `TransportMessage` and peer list.

**Broadcast semantics:** When `to` peer list is empty, send to ALL connected peers. Both platforms already support this.

**CompositeTransport:** Update relay dedup to handle new message types (channelAnnounce, fileHeader, fileChunk).

---

## 8. Migration Path

### 8.1 What to Delete (iOS)

- `ContentView.swift` (TabView root) → replace with `ChannelRootView`
- `ChatListView.swift` (peer-based chat list) → gone
- `ChatRoomView.swift` (1:1 chat room) → merged into `ChannelContentView`
- `WalkieTalkieView.swift` (separate PTT view) → merged into `ChannelContentView`
- `FileShareView.swift` (separate file view) → merged into `ChannelContentView`
- `NearbyView.swift` → reduce to status bar / bridge toggle (no standalone view)
- `ChatService.swift` → replaced by `ChannelService`
- `WalkieTalkieService.swift` → merged into `ChannelService`
- `FileShareService.swift` → merged into `ChannelService`
- `Models/ChatMessage.swift` → replaced by `ChannelMessage`
- `Models/Channel.swift` → replaced by updated `Channel`
- `Navigation/Route.swift` → simplify (no more tabs/routes)

### 8.2 What to Keep (iOS)

- `Core/TransportProtocol.swift` — interface unchanged
- `Core/MultipeerTransport.swift` — unchanged
- `Core/BLETransport.swift` — unchanged
- `Core/BLEConstants.swift` — unchanged
- `Core/CompositeTransport.swift` — update relay dedup
- `Core/TransportMessage.swift` — add new cases
- `Services/AudioEngine.swift` — unchanged
- `Services/Logging.swift` — unchanged
- `Navigation/AppCoordinator.swift` — simplify (remove tab/route state)

### 8.3 What to Delete (Android)

- `ui/chat/` (peer-based chat screens) → replace with channel content
- `ui/files/` (separate file UI) → merge into channel
- `ui/walkietalkie/` (separate PTT UI) → merge into channel
- `ui/nearby/` → reduce to status indicator
- `ui/AppNavigation.kt` → replace with single-view navigation
- `service/ChatService.kt` → replaced by `ChannelService`
- `service/WalkieTalkieService.kt` → merged into `ChannelService`
- `service/FileShareService.kt` → merged into `ChannelService`

### 8.4 What to Keep (Android)

- `core/TransportProtocol.kt` — interface unchanged
- `core/BLETransport.kt` — unchanged
- `core/NearbyTransport.kt` — unchanged
- `core/BLEConstants.kt` — unchanged
- `core/DataTag.kt` — unchanged
- `core/PeerInfo.kt` — unchanged
- `service/AudioEngine.kt` — unchanged

---

## 9. JSON Examples (Cross-Platform Reference)

### Text Message

```json
{
  "text": {
    "id": "F47AC10B-58CC-4372-A567-0E02B2C3D479",
    "channelID": "00000000-0000-0000-0000-000000000000",
    "senderID": "device-uuid-abc",
    "senderName": "Alice's iPhone",
    "content": "Hey everyone!",
    "timestamp": 796348800.0,
    "replyTo": null
  }
}
```

### Channel Announce

```json
{
  "channelAnnounce": {
    "channelID": "B2C3D479-58CC-4372-A567-F47AC10B0E02",
    "channelName": "Road Trip Photos",
    "createdAt": 796348800.0,
    "createdBy": "device-uuid-abc"
  }
}
```

### Floor Request

```json
{
  "walkieTalkieControl": {
    "requestFloor": {
      "channelID": "00000000-0000-0000-0000-000000000000",
      "peerID": "device-uuid-abc",
      "peerName": "Alice"
    }
  }
}
```

### File Header

```json
{
  "fileHeader": {
    "transferID": "C3D47900-58CC-4372-A567-F47AC10B0E02",
    "channelID": "00000000-0000-0000-0000-000000000000",
    "senderID": "device-uuid-abc",
    "senderName": "Alice's iPhone",
    "fileName": "sunset.jpg",
    "fileSize": 245760,
    "mimeType": "image/jpeg",
    "timestamp": 796348800.0
  }
}
```

### File Chunk

```json
{
  "fileChunk": {
    "transferID": "C3D47900-58CC-4372-A567-F47AC10B0E02",
    "index": 0,
    "totalChunks": 15,
    "data": "base64encodeddata..."
  }
}
```

---

## 10. Acceptance Criteria

### Must Have (v1.0)

- [ ] Single channel-based view replaces all 4 tabs
- [ ] Townsquare channel auto-exists, auto-joined, cannot be deleted
- [ ] Create new channels, visible to all peers via broadcast
- [ ] Text messages in channels, broadcast to all peers, filtered by channelID
- [ ] Push-to-talk per channel, floor control broadcast
- [ ] Audio playback filtered by activeChannelID
- [ ] File/photo sharing via chunked broadcast (works over BLE bridge)
- [ ] Bridge mode relays ALL message types (text, control, announce, file, audio)
- [ ] Channel sync on new peer connect
- [ ] Dedup prevents relay loops
- [ ] iOS SwiftData persistence for ChannelMessage
- [ ] Wire format compatible between iOS and Android

### Nice to Have (v1.1)

- [ ] Inline image preview in message list
- [ ] Unread message count per channel
- [ ] Reply-to threading (replyTo field is in the wire format, UI can come later)
- [ ] Audio codec (Opus) to reduce bandwidth over BLE
- [ ] Channel description / topic
- [ ] Peer presence indicators per channel

### Out of Scope

- User accounts or authentication
- Server-side anything
- Message encryption beyond transport-level (Multipeer is encrypted, BLE is not)
- Channel permissions or roles
- Message editing or deletion
- Offline message queue
- Android ↔ Android direct (requires Nearby Connections, not BLE)

---

## 11. Platform-Specific Notes

### iOS

- **Min target:** iOS 17+ (SwiftData, @Observable)
- **Navigation:** NavigationSplitView (iPad) / sheet-based sidebar (iPhone)
- **Persistence:** SwiftData for ChannelMessage. Channels are in-memory (re-synced on connect)
- **Audio session:** `.playAndRecord` with voice processing, same as current

### Android

- **Min SDK:** 26 (current)
- **UI:** Jetpack Compose, single-activity
- **Persistence:** In-memory (can add Room later)
- **Audio:** AudioRecord/AudioTrack with VOICE_COMMUNICATION, same as current
- **Date handling:** Convert Swift reference dates (epoch 2001-01-01) ↔ Unix timestamps

### Date Interop

Both platforms MUST use Swift reference dates on the wire:

```
swiftRefDate = unixTimestamp - 978307200.0
unixTimestamp = swiftRefDate + 978307200.0
```

Android converts on send/receive. iOS uses Date natively (which is Swift reference date internally).

---

## 12. Testing Strategy

### Unit Tests

- ChannelService: message routing by channelID, channel upsert idempotency, floor state machine
- Wire format: encode/decode roundtrip for all TransportMessage cases (Swift ↔ Kotlin parity)
- Dedup: relay loop prevention, TTL expiry, set overflow eviction
- File chunking: split → reassemble roundtrip, missing chunk handling

### Integration Tests

- Two iOS devices: create channel, send message, verify receipt and display
- iOS + Android via bridge: text message roundtrip, audio roundtrip, file transfer roundtrip
- Channel sync: late-joining peer receives all channels
- Bridge dedup: message sent from iOS A → bridge → Android B, does NOT echo back to iOS A

### Manual Smoke Tests

- Launch app → Townsquare visible → send text → appears in channel
- Create "Photos" channel → appears on other device → switch to it → send file
- PTT in Townsquare → audio heard on all devices including Android via bridge
- Kill and relaunch → Townsquare still exists → messages persisted (iOS) → channels re-sync on connect
