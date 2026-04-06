# Lessons Learned

## 1. Never replace a working transport with an untested one
**What happened**: Replaced MultipeerTransport with BLETransport for "cross-platform." Broke iOS-to-iOS which was working perfectly.
**Root cause**: Assumed BLE could replace Multipeer. Different protocols, different reliability.
**Resolution**: Reverted to MultipeerTransport for iOS, added BLE alongside.
**Decision**: Layer cross-platform on top of platform-native. Never remove what works.

## 2. Swift Codable `_0` wrapper breaks cross-platform JSON
**What happened**: Swift auto-synthesized Codable wraps unnamed enum associated values with `{"_0": {...}}`. Android's manual JSON builder doesn't include this.
**Root cause**: Relied on Swift's auto-generated Codable without checking actual JSON output.
**Resolution**: Custom `Codable` implementation on iOS. All cross-platform enums use labeled parameters.
**Decision**: Always validate wire format between platforms with actual JSON dumps. EVERY cross-platform enum needs custom Codable or labeled params.

## 3. BLE GATT cannot stream real-time audio
**What happened**: Audio at 16kHz mono float32 = 64 KB/s. BLE GATT effective throughput ~13 KB/s.
**Root cause**: BLE GATT was designed for small infrequent data, not continuous streaming.
**Resolution**: BLE demoted to control plane only. WiFi hotspot + TCP for audio.
**Decision**: Use GATT for control plane (discovery, metadata). Never send continuous data over BLE.

## 4. iOS CBCentralManager.connect often fails silently
**What happened**: iOS discovers Android's BLE peripheral but `didConnect` never fires. No error callback.
**Root cause**: Unknown — possibly simultaneous connection attempts or iOS BLE stack congestion.
**Resolution**: Peripheral-side notifications as fallback send path.
**Decision**: Don't rely solely on central-side connections. Always have bidirectional fallback.

## 5. Multiple iPhones named "iPhone" break peer identity
**What happened**: MCPeerID displayName was "iPhone" on all devices. Tiebreaker = false on both sides → no connection.
**Resolution**: Append random suffix to MCPeerID. Pass real device name in discoveryInfo for UI.
**Decision**: Always use unique identifiers for protocol-level identity.

## 6. Don't generate app icons with scripts
**What happened**: Python script generating PNGs produced garbage that broke the build.
**Decision**: Never script icon generation. User handles icons manually.

## 7. BLE is a control plane, not a data plane
**What happened**: Spent hours trying every BLE option (GATT, L2CAP, Classic BT). All failed or were blocked.
**Resolution**: Three-tier architecture — BLE control, Multipeer for iOS data, WiFi+TCP for cross-platform.
**Decision**: For high-bandwidth cross-platform P2P, use WiFi as data bridge bootstrapped by BLE.

## 8. BLE GATT operations are strictly sequential on Android
**What happened**: Peer info read issued after CCCD write. Read silently failed.
**Resolution**: Moved read to `onDescriptorWrite` callback. Chain all GATT operations via callbacks.
**Decision**: On Android, never issue two GATT operations back-to-back.

## 9. BLE default MTU is 23 bytes — negotiate before sending
**What happened**: JSON commands truncated to 20 bytes. `{"heartbeat":{"term"` was all that arrived.
**Resolution**: Request MTU 512 before service discovery. Discover services in `onMtuChanged`.
**Decision**: Always negotiate MTU before any data transfer on BLE.

## 10. Android hotspot AP interface is invisible to Java networking
**What happened**: `NetworkInterface.getNetworkInterfaces()` doesn't list the hotspot AP interface on many Android devices. `hostIP` was always null. TCP clients had nowhere to connect.
**Root cause**: Android kernel-level limitation. The AP interface exists but Java's networking APIs don't expose it.
**Resolution**: iOS discovers gateway IP via `getifaddrs()` after joining hotspot. Gateway = `(IP & mask) | 1` = Android. Also detect `wlan1`/`wlan2` as AP interfaces (not just `ap0`/`swlan0`).
**Decision**: Never rely on Android to report its own hotspot IP. Have the client discover it from the network layer.

## 11. AsyncStream is single-consumer — lost commands are silent
**What happened**: LeaderElection, NetworkCoordinator, and ChannelService all consumed `controlPlane.commands` (AsyncStream). Commands were randomly eaten by whichever consumer's `for await` loop ran first. WiFi credentials vanished → `wifiSSID` stayed nil → Multipeer selected instead of TCP → no cross-platform audio.
**Root cause**: AsyncStream delivers each element to exactly one consumer. No error, no warning. Commands silently disappear.
**Resolution**: NetworkCoordinator is the SOLE consumer. It fans out to `raftCommands` (LeaderElection), `channelCommands` (ChannelService), and processes network commands locally. Fixed twice — first for ChannelService, then for LeaderElection.
**Decision**: Any AsyncStream must have exactly ONE consumer. Fan-out via explicit re-publishing. If you add a new consumer, grep for existing `for await` loops on the same stream.

## 12. TCP ServerSocket needs SO_REUSEADDR
**What happened**: Android's `ServerSocket(port)` failed silently when a previous session's socket was in TCP TIME_WAIT (60s). The entire `startBroadcasting()` caught the exception and logged it, but no server started. iOS got "Connection refused."
**Root cause**: `ServerSocket(port)` doesn't set SO_REUSEADDR by default. Previous TCP connections linger in TIME_WAIT.
**Resolution**: `ServerSocket()` + `reuseAddress = true` + `bind(InetSocketAddress(port))`. Also close any lingering socket before starting a new one.
**Decision**: Always set SO_REUSEADDR on server sockets that may be restarted.

## 13. Android hotspot uses unpredictable subnets
**What happened**: `findHotspotIP()` fallback matched `192.168.43.x` and `192.168.49.x`. Device used `10.194.233.42` on `wlan2`. Hotspot IP detection returned null.
**Root cause**: Different Android devices and OS versions use different subnets for `startLocalOnlyHotspot()`. IP pattern matching is fragile.
**Resolution**: Detect AP interface by name: any `wlan*` that isn't `wlan0` (primary WiFi) is likely the AP. Falls back to IP patterns only as last resort.
**Decision**: Match AP interfaces by name heuristic, not IP pattern. `wlan0` = regular WiFi, anything else = likely AP.

## 14. Team agents need cleanup supervision
**What happened**: iOS dev agent created new files but didn't delete old ones. Build broke from conflicting types.
**Resolution**: Explicitly list files to delete in task descriptions. Verify build after agent completes.
**Decision**: When using team agents, always verify build. Agents create but rarely clean up.
