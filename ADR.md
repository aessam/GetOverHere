# Architecture Decision Records

## ADR-001: Multipeer Connectivity as primary iOS transport
**Date**: 2026-03-23
**Decision**: Use MultipeerConnectivity for iOS-to-iOS communication
**Context**: Need P2P without WiFi/cellular
**Options**: MultipeerConnectivity, BLE only, WiFi Direct
**Rationale**: MC handles discovery + data transfer automatically, uses Bluetooth + WiFi Direct under the hood, supports up to 8 peers
**Consequences**: iOS-only for same-platform. Need separate solution for Android.

## ADR-002: BLE for cross-platform discovery
**Date**: 2026-03-24
**Decision**: Use BLE GATT for cross-platform peer discovery and channel metadata
**Context**: iOS Multipeer and Android Nearby Connections are incompatible
**Options**: BLE, shared WiFi hotspot, mDNS
**Rationale**: BLE is the only universal radio that works without infrastructure on both platforms
**Consequences**: Limited bandwidth (~13 KB/s). Good for metadata, not for audio streaming.

## ADR-003: Channel-based megaphone architecture
**Date**: 2026-03-24
**Decision**: Audio-only megaphone with one speaker per channel (creator)
**Context**: Chat + files + walkie-talkie was too complex and unreliable
**Options**: Full chat app, walkie-talkie with floor control, megaphone
**Rationale**: Simplest possible model. One source, many listeners. No routing, no floor control, no identity management beyond creator check.
**Consequences**: No text chat, no file sharing. Pure audio broadcast.

## ADR-004: DualTransport (always-on Multipeer + BLE)
**Date**: 2026-03-24
**Decision**: Both transports run at boot, no bridge toggle
**Context**: Manual "bridge mode" was confusing and unreliable
**Rationale**: BLE scanning uses minimal power. Running both from the start ensures cross-platform discovery works immediately.
**Consequences**: Slightly higher battery usage. Simpler UX — no configuration needed.

## ADR-005: Custom Codable for wire format (no auto-synthesis)
**Date**: 2026-03-24
**Decision**: Hand-written Codable for BLECommand enum
**Context**: Swift's auto-synthesized Codable wraps unnamed enum associated values with `_0` key, which Android can't parse
**Rationale**: Custom Codable produces clean JSON matching what Android manually builds.
**Consequences**: Must manually update Codable when adding new message types.

## ADR-006: BLE L2CAP for cross-platform audio (ABANDONED)
**Date**: 2026-03-24
**Status**: Abandoned. Replaced by ADR-007.
**Decision**: Attempted L2CAP for audio streaming. Failed due to GATT PSM sharing sequencing issues.

## ADR-007: Three-tier architecture — BLE control + WiFi hotspot + TCP audio
**Date**: 2026-03-24
**Decision**: BLE as control plane only. Android creates WiFi hotspot. TCP for audio streaming.
**Context**: BLE GATT can't handle audio bandwidth. L2CAP PSM sharing failed. Classic BT blocked on iOS.
**Options**: (a) Keep debugging BLE L2CAP, (b) WiFi hotspot + TCP, (c) No cross-platform audio
**Rationale**: WiFi provides unlimited bandwidth. Android creates hotspot via `startLocalOnlyHotspot`, iOS joins via `NEHotspotConfigurationManager`. BLE handles bootstrap. Clean separation of concerns.
**Consequences**: Requires Android device as WiFi host for cross-platform. iOS-only groups use MultipeerConnectivity.

## ADR-008: RAFT leader election for WiFi host selection
**Date**: 2026-03-24
**Decision**: Simplified RAFT protocol to elect leader who coordinates the network.
**Context**: Need to decide who becomes WiFi host without conflicts.
**Rationale**: Term numbers + heartbeat, no log replication. Android preferred as leader.
**Consequences**: Android leads when present. iOS leads in iOS-only groups.

## ADR-009: TCP instead of UDP for cross-platform audio
**Date**: 2026-03-25
**Decision**: Switch from UDP broadcast/multicast to TCP server/client for audio.
**Context**: Android's hotspot AP interface is invisible to `NetworkInterface.getNetworkInterfaces()`. UDP broadcast targets couldn't be determined.
**Options**: (a) Fix UDP broadcast target, (b) Switch to TCP, (c) Use multicast
**Rationale**: TCP is point-to-point — speaker runs server, listeners connect. No need to know broadcast address. Length-prefixed packets: `[4 bytes big-endian length][PCM data]`.
**Consequences**: Speaker must run a TCP server. Listeners need the speaker's IP address to connect.

## ADR-010: iOS gateway IP discovery for Android hotspot
**Date**: 2026-03-27
**Decision**: After iOS joins Android's hotspot, discover the gateway IP via `getifaddrs()`. Gateway = Android's IP.
**Context**: Android can't report its own hotspot IP (`NetworkInterface` doesn't see the AP interface). `hostIP` was always null in wifiCredentials.
**Options**: (a) Fix Android IP discovery, (b) iOS discovers gateway, (c) Hardcode common subnets
**Rationale**: `getifaddrs()` on en0 reliably gives iOS's local IP and netmask. Gateway = `(IP & mask) | 1` — standard for Android hotspot subnets. Works regardless of the subnet Android chooses (192.168.43.x, 192.168.49.x, 10.x.x.x).
**Consequences**: iOS always knows where Android is. Android's `findHotspotIP()` is best-effort fallback.

## ADR-011: audioHostIP in channelAnnounce for reverse direction
**Date**: 2026-03-27
**Decision**: Include the speaker's WiFi IP in channelAnnounce BLE command.
**Context**: When iOS creates a channel and Android wants to listen, Android needs iOS's IP to connect TCP client. Gateway discovery only works iOS→Android direction.
**Rationale**: iOS knows its own IP from `getifaddrs()`. Include it in the announce. Android uses it directly.
**Consequences**: Both directions work: iOS listens to Android (gateway IP), Android listens to iOS (audioHostIP from announce).

## ADR-012: AsyncStream fan-out via NetworkCoordinator
**Date**: 2026-03-27
**Decision**: NetworkCoordinator is the SOLE consumer of `controlPlane.commands` (AsyncStream). It fans out to `channelCommands`, `raftCommands`, and processes network commands locally.
**Context**: AsyncStream is single-consumer. LeaderElection, ChannelService, and NetworkCoordinator were all consuming the same stream — commands were randomly lost.
**Options**: (a) Switch to AsyncBroadcastSequence, (b) Fan out from single consumer, (c) Use Combine
**Rationale**: Fan-out from a single consumer is simplest and most explicit. No new dependencies. Each consumer gets its own AsyncStream.
**Consequences**: Adding new command consumers requires adding a new re-published stream in NetworkCoordinator.

## ADR-013: Bonjour LocalControlPlane for same-network scenarios
**Date**: 2026-03-27
**Decision**: Add Bonjour-based control plane (`LocalControlPlane`) as alternative to BLE.
**Context**: When devices are on the same WiFi network, BLE discovery adds complexity and latency. Bonjour provides instant same-network discovery.
**Rationale**: Bonjour uses mDNS — zero config, works on any local network, supported by both iOS and Android (via NSD). Simpler than BLE GATT for the same-network case.
**Consequences**: BLE still needed for the no-infrastructure case. Two control plane implementations to maintain.

## ADR-014: Monorepo structure (iOS/ + Android/)
**Date**: 2026-04-05
**Decision**: Both platform projects live in the same repository under `iOS/` and `Android/` directories.
**Context**: Projects were in separate repositories. Cross-platform protocol changes required syncing two repos.
**Rationale**: Single repo ensures protocol changes (BLECommand JSON format, channelAnnounce fields) are atomic. Shared docs (ADR, LessonsLearned) live at root.
**Consequences**: Larger repo. Android and iOS developers both see the whole project.
