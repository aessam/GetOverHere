# Lessons Learned

## 1. Never replace a working transport with an untested one
**What happened**: Replaced MultipeerTransport with BLETransport for "cross-platform." Broke iOS-to-iOS which was working perfectly.
**Root cause**: Assumed BLE could replace Multipeer. Different protocols, different reliability.
**Resolution**: Reverted to MultipeerTransport for iOS, added BLE alongside.
**Decision**: Layer cross-platform on top of platform-native. Never remove what works.

## 2. Swift Codable `_0` wrapper breaks cross-platform JSON
**What happened**: Swift auto-synthesized Codable wraps unnamed enum associated values with `{"_0": {...}}`. Android's manual JSON builder doesn't include this. Neither side could parse the other's messages.
**Root cause**: Relied on Swift's auto-generated Codable without checking the actual JSON output.
**Resolution**: Custom `Codable` implementation on iOS (no `_0`), plus `unwrap0()` on Android for safety.
**Decision**: Always validate wire format between platforms with actual JSON dumps. Never trust auto-generated serialization for cross-platform.

## 3. BLE chunk flags overlap with DataTag values
**What happened**: ChunkFlag 0x01/0x02 and DataTag.message (0x01) / DataTag.audio (0x02) use the same byte values. Audio packets were misinterpreted as chunk flags, corrupting data.
**Root cause**: Protocol designed without considering the full byte space. Two layers using overlapping values at the same byte position.
**Resolution**: Always use chunk framing (SINGLE flag 0x03) for all BLE data, even audio. Receiver checks for chunk flags first.
**Decision**: In next refactor, change chunk flags to 0xF0-0xF3 to eliminate overlap.

## 4. BLE GATT cannot stream real-time audio
**What happened**: Audio at 16kHz mono float32 = 64 KB/s. BLE GATT effective throughput ~13 KB/s with 39ms connection interval. Audio was choppy (Android→iOS) or silent (iOS→Android, notification queue overflow).
**Root cause**: BLE GATT was designed for small infrequent data, not continuous streaming.
**Resolution**: Moving to BLE L2CAP channels which provide stream-oriented connections at 100+ KB/s.
**Decision**: Use GATT for control plane (discovery, metadata), L2CAP for data plane (audio).

## 5. iOS CBCentralManager.connect often fails silently
**What happened**: iOS discovers Android's BLE peripheral but `didConnect` never fires. No error callback either. The connection attempt hangs forever.
**Root cause**: Unknown — possibly related to both devices connecting simultaneously, or iOS BLE stack congestion.
**Resolution**: Added peripheral-side notifications as fallback send path. When central writes fail, data goes via `peripheralManager.updateValue` to subscribed centrals.
**Decision**: Don't rely solely on central-side connections. Always have a bidirectional fallback.

## 6. Multiple iPhones named "iPhone" break peer identity
**What happened**: MCPeerID displayName was "iPhone" on all devices. Tiebreaker comparison `"iPhone" < "iPhone"` = false on both sides → neither invites → no connection.
**Root cause**: Used device name directly for MCPeerID without ensuring uniqueness.
**Resolution**: Append random 4-char suffix to MCPeerID (`iPhone_A3F2`). Pass real device name in discoveryInfo for UI display.
**Decision**: Always use unique identifiers for protocol-level identity. Display names are for humans only.

## 7. Team agents need cleanup supervision
**What happened**: iOS dev agent created new files but didn't delete old ones. Build broke from conflicting types. Had to manually empty 12 stale files.
**Root cause**: Agent was focused on creating new code, didn't clean up the old code it was supposed to replace.
**Resolution**: Team lead manually cleaned up stale files and fixed build errors.
**Decision**: When using team agents, explicitly list files to delete in the task description. Verify build after agent completes.

## 8. Don't generate app icons with scripts
**What happened**: Python script generating 1024x1024 PNGs produced garbage that broke the build.
**Resolution**: User handles icons manually via Xcode asset catalog.
**Decision**: Never script icon generation. Icons are a design task, not a code task.

## 9. BLE is a control plane, not a data plane
**What happened**: Spent hours trying to stream 64 KB/s audio over BLE GATT (~13 KB/s throughput). Then tried L2CAP — PSM sharing broke due to GATT operation sequencing. Every fix revealed another BLE edge case.
**Root cause**: BLE was designed for small, infrequent data (sensor readings, notifications). Using it for continuous audio streaming is fighting the technology.
**Resolution**: BLE demoted to control plane only (discovery, commands, metadata). WiFi hotspot + UDP for audio data plane.
**Decision**: Never send continuous data over BLE. Use it for what it's good at: discovery and lightweight coordination.

## 10. WiFi hotspot is the cross-platform data bridge
**What happened**: Explored every Bluetooth option (GATT, L2CAP, Classic BT). All failed or were blocked on iOS.
**Root cause**: iOS blocks Classic BT for third-party apps. BLE bandwidth is insufficient. WiFi Direct has no public iOS API.
**Resolution**: Android creates WiFi hotspot (`startLocalOnlyHotspot`), iOS joins (`NEHotspotConfigurationManager`), audio over UDP multicast.
**Decision**: For high-bandwidth cross-platform P2P, use WiFi as the data bridge, bootstrapped by BLE.

## 11. Separate control plane from data plane
**What happened**: Mixed BLE discovery, metadata, and audio in the same transport. Chunk framing conflicts, byte overlaps, notification queue overflows.
**Root cause**: Single transport trying to handle both lightweight commands and heavy data. Different reliability requirements, different bandwidth needs.
**Resolution**: Three-tier architecture — BLE control plane, Multipeer for iOS data, WiFi+UDP for cross-platform data.
**Decision**: Always separate control plane (lightweight, reliable) from data plane (high bandwidth, can tolerate loss).
