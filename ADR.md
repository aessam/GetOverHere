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

## ADR-006: BLE L2CAP for cross-platform audio (PENDING)
**Date**: 2026-03-24
**Decision**: Use BLE L2CAP channels for audio streaming, keep GATT for metadata
**Context**: GATT notifications can only do ~13 KB/s, audio needs 64 KB/s
**Options**: Reduce audio quality, use L2CAP, accept no cross-platform audio
**Rationale**: L2CAP provides stream-oriented BLE connections at 100+ KB/s. Both iOS 11+ and Android 10+ support it.
**Consequences**: More complex BLE code (L2CAP + GATT). But solves the bandwidth problem without sacrificing audio quality.
**Status**: Approved, implementation next session.
