# GetOverHere / ComeOverHere — Spec

**Version:** 2.0 (Megaphone rewrite)
**Date:** 2026-04-05
**Supersedes:** v1.0 (multi-feature chat/files/walkie-talkie)

---

## Product Vision

P2P audio megaphone. One speaker per channel, everyone else listens. No backend, no accounts. Works cross-platform (iOS + Android) on any shared network or via Android WiFi hotspot.

## Functional Requirements

### Channels

| Requirement | Detail |
|-------------|--------|
| Create channel | User enters name → becomes the speaker → channel announced to all peers |
| Join channel | Tap discovered channel → become listener → audio streams from speaker |
| Leave channel | Speaker leaves → channel ends for everyone. Listener leaves → just stops receiving |
| Discovery | Channels discovered via BLE control plane and/or Bonjour. Periodic re-broadcast every 5s |
| One speaker | Only the creator can broadcast audio. No floor control, no hand-off |

### Audio

| Requirement | Detail |
|-------------|--------|
| Standard quality | 16 kHz mono float32 (~64 KB/s) |
| HD quality | 44.1 kHz stereo float32 (~353 KB/s) |
| Quality selection | Creator chooses quality at channel creation time |
| Earpiece mode | Listener toggle — routes audio to earpiece instead of speaker |
| Format conversion | Both platforms convert hardware audio format → wire format before sending |

### Cross-Platform

| Requirement | Detail |
|-------------|--------|
| iOS-to-iOS | MultipeerConnectivity or TCP on same network |
| iOS-to-Android | BLE discovery → Android WiFi hotspot → TCP audio |
| Android-to-Android | Same hotspot network → TCP audio |
| No infrastructure | Works without WiFi router or cell tower (via Android hotspot) |
| Same network | Works on any shared WiFi (via Bonjour + TCP) |

### Network

| Requirement | Detail |
|-------------|--------|
| BLE control plane | GATT service for discovery, commands, metadata |
| Leader election | Simplified RAFT. Android preferred as leader (can create hotspot) |
| WiFi hotspot | Android creates via `startLocalOnlyHotspot`. iOS joins via `NEHotspotConfigurationManager` |
| TCP audio | Speaker runs server on port 50000. Listeners connect. Length-prefixed PCM packets |
| Gateway discovery | iOS finds Android's IP via `getifaddrs` gateway computation after joining hotspot |

## Non-Functional Requirements

| Requirement | Detail |
|-------------|--------|
| Latency | Sub-second audio latency over local network |
| Battery | BLE scanning is low power. Audio capture/playback is the main drain |
| Reliability | TCP ensures ordered delivery. SO_REUSEADDR prevents port conflicts |
| Security | No authentication. Anyone on the network can join. Future: channel passwords |

## Out of Scope (v2.0)

- Text chat
- File/photo sharing
- Push-to-talk floor control
- Multiple speakers per channel
- Channel passwords
- Persistent channels (channels exist only while creator is active)
- Cloud backup or sync
