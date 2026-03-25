# Architecture Decision Records

## ADR-001: Multipeer Connectivity as primary iOS transport
**Date**: 2026-03-23
**Decision**: Use MultipeerConnectivity for iOS↔iOS communication
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
**Consequences**: No text chat, no file sharing. Pure audio broadcast. Can add features later on top of this foundation.

## ADR-004: DualTransport (always-on Multipeer + BLE)
**Date**: 2026-03-24
**Decision**: Both transports run at boot, no bridge toggle
**Context**: Manual "bridge mode" was confusing and unreliable
**Options**: Manual bridge toggle, auto-enable on channel creation, always-on
**Rationale**: BLE scanning uses minimal power. Running both from the start ensures cross-platform discovery works immediately.
**Consequences**: Slightly higher battery usage. Simpler UX — no configuration needed.

## ADR-005: Custom Codable for wire format (no auto-synthesis)
**Date**: 2026-03-24
**Decision**: Hand-written Codable for TransportMessage enum
**Context**: Swift's auto-synthesized Codable wraps unnamed enum associated values with `_0` key, which Android can't parse
**Options**: Custom Codable on iOS, unwrap `_0` on Android, use a different serialization
**Rationale**: Custom Codable produces clean JSON matching what Android manually builds. Both sides control the exact wire format.
**Consequences**: Must manually update Codable when adding new message types.

## ADR-006: BLE L2CAP for cross-platform audio (ABANDONED)
**Date**: 2026-03-24
**Decision**: Attempted L2CAP for audio streaming. Failed due to GATT PSM sharing sequencing issues.
**Status**: Abandoned. Replaced by ADR-007.

## ADR-007: Three-tier architecture — BLE control + WiFi hotspot + UDP audio
**Date**: 2026-03-24
**Decision**: BLE as control plane only. Android creates WiFi hotspot for cross-platform audio. UDP multicast for audio streaming.
**Context**: BLE GATT can't handle audio bandwidth (~13 KB/s vs 64 KB/s needed). BLE L2CAP PSM sharing failed. Classic BT blocked on iOS. Need a reliable cross-platform audio path.
**Options**: (a) Keep debugging BLE L2CAP, (b) WiFi hotspot + UDP, (c) Accept no cross-platform audio
**Rationale**: WiFi provides unlimited bandwidth for audio. Android can create hotspot programmatically (`startLocalOnlyHotspot`). iOS can join programmatically (`NEHotspotConfigurationManager`). BLE handles the bootstrap (discovery, leader election, credential exchange). Clean separation of concerns.
**Consequences**: Requires Android device as WiFi host when cross-platform is needed. iOS-only groups still use MultipeerConnectivity (no change). Clean rewrite of transport layer needed.

## ADR-008: RAFT leader election for WiFi host selection
**Date**: 2026-03-24
**Decision**: Use simplified RAFT protocol to elect a leader who coordinates the network.
**Context**: With multiple devices, need to decide who becomes the WiFi host. Can't have everyone creating hotspots.
**Rationale**: RAFT is well-understood, handles network partitions, and naturally selects one leader. Simplified version: just term numbers + heartbeat, no log replication.
**Consequences**: Android devices preferred as leaders (can create hotspot). iOS leads only in iOS-only groups.

## ADR-009: Cross-platform channel discovery proven via BLE control plane
**Date**: 2026-03-24
**Decision**: BLE control plane architecture works. Android discovers iOS channels via JSON commands over GATT.
**Evidence**: Log `ChannelService: Discovered megaphone: I tttt` on Android after iOS created channel.
**Flow proven**: BLE discovery → GATT connect → MTU negotiate → peer info exchange → channel announce broadcast → periodic re-broadcast → channel appears on remote device.
**Remaining**: iOS→Android direction (iOS central connection unreliable), UDP audio over WiFi hotspot.
