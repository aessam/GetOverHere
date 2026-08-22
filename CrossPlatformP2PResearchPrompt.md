# Cross-Platform P2P Deep Research Prompt

You are performing a deep technical architecture investigation for a native iOS/Android product. Work independently. Do not assume the current design or proposed technologies are correct.

Current date: 2026-08-20.

Project vision
==============

The product is a serverless tour-guide system:

- One tour guide speaks into an iPhone or Android phone.
- All nearby guests hear the guide with low latency.
- The guide can send and remotely control a synchronized slideshow on every guest’s screen.
- The guide can point their phone toward a landmark and make every guest’s screen show an arrow pointing toward the same real-world bearing.
- Cellular data and internet must not be required.
- iOS and Android must interoperate.
- The guide may use either platform.
- Expected group sizes need investigation: 10, 20, 50, and potentially 100 guests.
- Guests move together outdoors, potentially through crowded RF environments.
- Joining must be simple enough for tourists.
- The app should remain privacy-first and avoid unnecessary cloud infrastructure or telemetry.

Repository
==========

If you have filesystem access, inspect this repository read-only:

`/Users/aessam/tmp/ios-macos-apps/GetOverHere`

Do not edit any files.

It is a native monorepo:

- iOS: Swift/SwiftUI
- Android: Kotlin/Compose
- iOS project: `iOS/GetOverHere.xcodeproj`
- Android project: `Android/`

Current implementation
======================

The active runtime currently uses a shared local Wi-Fi network:

iOS:

```swift
let controlPlane: LocalControlPlane
private let udpAudio = UDPAudioPlane()

func selectAudioPlane() -> any AudioPlane {
    activeAudioPlane = udpAudio
    return udpAudio
}
```

Android:

```kotlin
val controlPlane = LocalControlPlane(context, displayName)
val udpAudio = UDPAudioPlane()

fun selectAudioPlane(): AudioPlane {
    activeAudioPlane = udpAudio
    return udpAudio
}
```

Despite its name, `UDPAudioPlane` is TCP:

- Bonjour/Android NSD discovery using `_goh-audio._tcp`
- Guide runs TCP server on port 50000
- Guests connect directly
- Packet framing: `[4-byte big-endian length][audio bytes]`
- Guide keeps one client socket per listener

Current audio format:

- 16 kHz
- Mono
- Float32 PCM
- 64 KB/s / 512 kbps per listener
- No compression
- The UI offers “HD,” but both audio engines currently always use the standard format

Existing but unused code:

- iOS and Android BLE control planes
- Simplified leader election
- Android LocalOnlyHotspot manager
- iOS hotspot joiner
- iOS MultipeerConnectivity audio plane
- Google Play Services Nearby dependency on Android
- Android `NearbyTransport.kt` is only a placeholder
- No Google Nearby Connections package is installed on iOS

Missing product features:

- No slide transfer/cache/manifest
- No guide-side presentation controls
- No synchronized presentation state
- No compass/bearing protocol or UI
- No reconnect state snapshot
- Listener count is currently not a real listener count
- Automated tests are stale from an abandoned chat/files/walkie-talkie architecture

Known platform facts that must be independently verified
========================================================

Do not blindly accept these:

1. Apple MultipeerConnectivity/Apple peer-to-peer Wi-Fi cannot directly interoperate with Android Wi-Fi Direct through public APIs.
2. MultipeerConnectivity has been deprecated in favor of Network framework.
3. Google Nearby Connections now supports Android/iOS interoperability, offline discovery, Star/Cluster/Point-to-Point topologies, and byte/file/stream payloads.
4. Google does not publish a fixed numeric maximum for Star or Cluster participants.
5. Wi-Fi Aware/NAN is a cross-platform standard available on iOS 26 and supported Apple hardware, while Android support and connection counts vary by device.
6. Wi-Fi Aware pairing support on Android has different OS/hardware requirements from basic Wi-Fi Aware.
7. Nearby Cluster is “mesh-like” connectivity but does not automatically provide application-level multi-hop routing.
8. Opus would reduce voice bandwidth substantially compared with raw PCM.

Research task
=============

Determine the best architecture for this product.

Compare at least:

- Google Nearby Connections on both platforms
- Native Wi-Fi Aware/NAN
- Shared Wi-Fi with Bonjour/NSD and standard TCP/UDP
- Android LocalOnlyHotspot with iOS joining
- Apple peer-to-peer Wi-Fi / Network framework
- MultipeerConnectivity
- Android Wi-Fi Direct
- BLE as discovery/control only
- Any better documented alternative you find

Answer these questions:

1. Can Google Nearby Connections establish a genuinely infrastructure-free Android-to-iOS high-bandwidth connection today, or does some cross-platform path still require both devices on the same Wi-Fi LAN?

2. Which physical transports can Google Nearby Connections select for Android-to-iOS communication? Separate documented facts from assumptions.

3. Does Google Nearby Connections support one guide streaming to many guests efficiently, or does it duplicate one stream per endpoint?

4. What connection limits are documented for Nearby Star, Nearby Cluster, Apple Wi-Fi Aware, and Android Wi-Fi Aware?

5. Where limits are runtime/device-specific, identify the exact APIs used to query them.

6. Distinguish:
   - Multiple direct peer connections
   - Mesh-like topology
   - Automatic multi-hop routing
   - Application-implemented relaying

7. Would application-level mesh relaying materially help this tour use case? Analyze:
   - Range extension
   - Latency per hop
   - Duplicate suppression
   - Routing
   - Failover
   - Battery and heat
   - Background suspension
   - Security
   - Guests leaving unpredictably
   - Mixed iOS/Android behavior

8. Model bandwidth for 10, 20, 50, and 100 listeners using:
   - Current raw PCM
   - Opus narrowband/wideband/fullband voice at defensible documented bitrates
   - TCP unicast
   - Any viable multicast/broadcast mechanism

9. Investigate whether multicast is practical on both platforms, including:
   - Apple multicast entitlement requirements
   - Android `MulticastLock`
   - LocalOnlyHotspot behavior
   - Client isolation on common Wi-Fi networks
   - Packet loss, jitter, and encryption implications

10. Determine the best audio transport:
    - Nearby stream payload
    - TCP
    - UDP/RTP
    - QUIC
    - Another option
    Include latency, jitter buffering, packet-loss handling, congestion, reconnection, and one-to-many scaling.

11. Design the slide/control path:
    - Asset manifest
    - Image transfer and caching
    - Checksums
    - Show/hide/next/previous commands
    - Late joiners
    - Reconnect state snapshot
    - Avoiding slide transfers from blocking audio

12. Design the bearing-arrow path:
    - Guide captures an absolute magnetic or true bearing
    - Guests rotate the arrow relative to their own heading
    - Required sensors and permissions
    - Calibration and magnetic interference
    - Update frequency
    - Whether location permission is necessary
    - Expected accuracy limitations

13. Evaluate onboarding:
    - App installation before the tour
    - Pairing UI
    - Joining 20–50 guests without approving each individually
    - QR codes/group codes
    - Authentication
    - Preventing nearby strangers from joining
    - Rejoining after temporary disconnect

14. Evaluate background behavior:
    - Guide locks their screen
    - Guest locks their screen
    - App moves to background
    - Audio continues
    - Slides/arrows require foreground
    - iOS and Android restrictions

15. Evaluate privacy and dependency risks:
    - Google Nearby telemetry/data collection
    - Google Play Services availability
    - Regions/devices without Play Services
    - Apple entitlements
    - App Store/Play policy risks
    - Whether a no-Google native fallback is required

Research standards
==================

- Use current information as of 2026-08-20.
- Use primary sources: Apple documentation, Android documentation/AOSP, Google Nearby documentation/source, Wi-Fi Alliance material, IETF RFCs, and official SDK release notes.
- Do not use random blogs as authority.
- Cite every important claim with a direct link.
- Quote exact documented limits where they exist.
- Do not invent a participant limit when the vendor publishes only `N`.
- Separate:
  - Documented fact
  - Measurement from a benchmark
  - Engineering inference
  - Unknown requiring experiment
- Identify outdated documentation and version-specific behavior.
- Do not reverse engineer private APIs.
- Challenge the premise that mesh is necessary.
- Challenge the premise that Google Nearby is the best choice.
- Give one primary recommendation and one fallback, not an unranked option dump.

Required output
===============

1. Executive verdict
   - Can the full product be built?
   - Recommended primary transport
   - Recommended fallback
   - Whether mesh should be used
   - Defensible initial group-size target

2. Technology comparison table
   - Cross-platform
   - No internet
   - No access point
   - Minimum OS/hardware
   - Topology
   - Stream/file/control support
   - Documented connection limit
   - Background behavior
   - Permissions/entitlements
   - Privacy/dependency concerns

3. Capacity model
   - Formulae
   - 10/20/50/100 listener table
   - Raw PCM versus Opus
   - Likely bottlenecks

4. Mesh analysis
   - Direct peer topology versus multi-hop
   - Benefits, failure modes, and recommendation

5. Recommended architecture
   - Text diagram
   - Discovery/pairing
   - Audio
   - Slides
   - Control state
   - Bearing
   - Reconnect
   - Security
   - Fallback selection

6. Protocol sketch
   - Typed messages and important fields
   - Versioning
   - Sequence numbers
   - State synchronization
   - Asset integrity

7. Physical-device experiment plan
   - Smallest useful spike
   - Device/OS matrix
   - 8, 16, 32, and 50 participant gates
   - Duration
   - Metrics
   - Failure injection
   - Explicit go/no-go criteria

8. Repository impact
   - What current components should remain
   - What should be replaced
   - What should not be built yet
   - Do not edit the repository

9. Premortem
   - Five most likely reasons this architecture fails during a real tour
   - Detection and mitigation

10. Unknowns and disputed claims
    - Explicitly list everything that still requires physical verification

11. Sources
    - Direct primary-source links mapped to claims

Return the report in your response. Do not modify or create project files.

---

## Optional CLI Runs

Copy the prompt above, then run one or more of:

```bash
cd /Users/aessam/tmp/ios-macos-apps/GetOverHere
codex exec "$(pbpaste)"
gemini -p "$(pbpaste)"
claude -p "$(pbpaste)"
```
