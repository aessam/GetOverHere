# Next Session

**Date:** 2026-04-05
**Status:** Cross-platform audio WORKING in both directions

## What's Done

- Monorepo: `iOS/` (Xcode) + `Android/` (Gradle) in same repo
- Megaphone architecture: one speaker per channel, everyone else listens
- BLE control plane for cross-platform discovery + commands
- Bonjour (LocalControlPlane) for same-network discovery
- TCP audio with length-prefixed PCM packets
- iOS gateway IP discovery for Android hotspot
- audioHostIP in channelAnnounce for reverse direction
- AsyncStream fan-out fix (LeaderElection was stealing commands)
- SO_REUSEADDR on TCP server sockets
- Android AP interface detection (wlan1/wlan2 heuristic)

## What's Next

- TestFlight deployment
- Audio quality improvements (latency, buffer tuning)
- Channel passwords / access control
- UI polish (waveform visualizer, connection status indicators)
- Handle WiFi disconnection gracefully (auto-reconnect)
- Multiple listener stress testing (3+ devices)
