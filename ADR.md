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
**Status**: Partially superseded by ADR-029. BLE remains the universal discovery/control radio; compressed, expiring live voice is now accepted as a gated fallback experiment.
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
**Status**: Superseded by ADR-029. Android-hosted Wi-Fi was unstable in physical use and is not a production dependency.
**Decision**: BLE as control plane only. Android creates WiFi hotspot. TCP for audio streaming.
**Context**: BLE GATT can't handle audio bandwidth. L2CAP PSM sharing failed. Classic BT blocked on iOS.
**Options**: (a) Keep debugging BLE L2CAP, (b) WiFi hotspot + TCP, (c) No cross-platform audio
**Rationale**: WiFi provides unlimited bandwidth. Android creates hotspot via `startLocalOnlyHotspot`, iOS joins via `NEHotspotConfigurationManager`. BLE handles bootstrap. Clean separation of concerns.
**Consequences**: Requires Android device as WiFi host for cross-platform. iOS-only groups use MultipeerConnectivity.

## ADR-008: RAFT leader election for WiFi host selection
**Date**: 2026-03-24
**Status**: Superseded by ADR-029. The product has one explicit guide, no elected hotspot host, and only bounded successor selection inside the BLE overlay.
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

## ADR-015: Native Wi-Fi Aware as an isolated cross-platform experiment
**Date**: 2026-08-21
**Status**: Selected primary transport direction by ADR-029, still isolated from production until physical Android-to-iOS gates pass.
**Decision**: Implement a native Wi-Fi Aware publisher/subscriber lab on both platforms behind a separate UI. Use `_goh-probe._udp`, authenticated platform pairing, a NAN data path, and a shared 28-byte binary frame header. Exercise the path with deterministic 45-byte payloads every 20 ms, representing an 18 kb/s Opus payload rate.
**Context**: The selected option was direct native Wi-Fi Aware rather than a portable access point. Current vendor documentation does not prove Android-to-iOS interoperability on the target devices, so production integration before a physical result would hide the key risk.
**Options**: (a) Replace production networking immediately, (b) isolated physical-device lab, (c) portable access point architecture.
**Rationale**: The lab measures discovery, pairing, NDP establishment, loss, malformed frames, and p95 round-trip time without coupling an unproven transport to channel/audio state.
**Consequences**: The iOS lab requires iOS 26.4 at runtime and the Wi-Fi Aware entitlement and service declaration, while the production target remains iOS 17. Android requires `NEARBY_WIFI_DEVICES` only when entering the lab. The app transport remains unchanged. A provisioning profile containing `com.apple.developer.wifi-aware` and a successful mixed-device probe are required before promotion.

## ADR-016: Private listener output is the default anti-feedback mode
**Date**: 2026-08-21
**Status**: Accepted; physical echo A/B pending.
**Decision**: Route listener audio to the earpiece or a connected headset by default. Provide an explicit Speaker override with a feedback warning. Use voice-communication capture processing where the active route supports it.
**Context**: A nearby listener loudspeaker plays delayed guide audio back into the guide microphone. The guide then rebroadcasts it, producing an audible echo even though the transport sends each audio frame once. Platform AEC is designed around a device's own playback reference and cannot reliably cancel arbitrary neighboring phones.
**Rationale**: Preventing the delayed signal from reaching the guide microphone is simpler and more reliable than adding custom adaptive echo cancellation. The speaker override preserves flexibility when devices are separated.
**Consequences**: Guests normally listen through the receiver or headphones. Loudspeaker mode remains available but is explicitly identified as echo-prone near the guide. Custom WebRTC AEC remains out of scope unless physical testing shows private output is insufficient.

## ADR-017: GOH2 transport-neutral session protocol
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Use a deterministic binary GOH2 envelope shared by a local Swift package and a pure Kotlin/JVM module. Every frame declares its protocol version, lane, message kind, sequence, session ID, sender ID, and payload length. Realtime audio, reliable control state, and slide assets are separate protocol lanes. Presentation and bearing changes are authoritative versioned snapshots; slide data is content-addressed by SHA-256 and transferred as manifests and resumable chunks.
**Context**: The legacy app mixed discovery state with session state and had no cross-platform contract for slides, direction pointers, reconnect, or participant identity. Adding each feature directly to platform transports would duplicate state logic and make wire drift likely.
**Options**: (a) extend the legacy JSON/BLE commands, (b) define platform-specific protocols, (c) establish one transport-neutral binary session core.
**Rationale**: Deterministic manual encoding permits exact Swift/Kotlin byte comparisons on the development machine. Lane validation prevents asset data from entering the realtime path. Stable participant IDs allow reconnect replacement and correct counts.
**Consequences**: Both mobile apps depend on the shared session cores. Any wire change requires equivalent Swift/Kotlin roundtrip tests and an intentional protocol-version decision. Per-tour authentication is defined separately by ADR-023.

## ADR-018: Listener count comes from validated session membership
**Date**: 2026-08-21
**Status**: Accepted for local-LAN transport; Wi-Fi Aware physical validation pending.
**Decision**: Count live guest sessions after a valid GOH2 hello on the data connection. Do not derive listeners from Bonjour/NSD discovery peers or raw socket count. A new connection with the same participant ID replaces and closes the previous connection.
**Context**: Android could stream to an iPhone while displaying zero listeners because the UI counted control-plane discovery peers. Duplicate TCP connections could also overcount or deliver duplicate audio.
**Rationale**: The guide can only claim a listener after that guest joins the actual channel transport. Stable identity handles reconnects without inflation, and socket close removes the participant.
**Consequences**: Legacy builds without an authenticated GOH2 hello no longer interoperate with updated builds. Participant admission follows ADR-023.

## ADR-019: Independent reliable control and asset channels
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Keep audio, authoritative session control, and tour-pack assets on three independent framed sockets. Control uses port 50001. Assets use port 50002 and a request-driven 64 KiB chunk protocol. Every socket performs the same GOH2 hello/welcome handshake and binds later frames to the authenticated participant ID. Asset requests are targeted per guest; completed content is stored by lowercase SHA-256 only after length and checksum verification.
**Context**: Slides, offline map archives, presentation state, and dropped pins have different latency and reliability requirements. Sending a large map or image through the audio or control FIFO would create head-of-line stalls. Blindly enqueueing a whole file would also allow one slow guest to consume unbounded memory.
**Options**: (a) one reliable socket for everything, (b) audio plus one shared control/asset socket, (c) three independent traffic classes.
**Rationale**: The third socket is a small present cost and prevents asset traffic from delaying speech or guide commands. One request per chunk provides natural backpressure, restart-safe offsets, bounded memory, and per-guest progress without adding another acknowledgement format.
**Consequences**: The app maintains three connections per guest. Tour-pack manifests, asset requests, chunks, and readiness statuses require exact Swift/Kotlin wire tests. A guest is presentation-ready only after every unique hash in the current manifest reports verified readiness.

## ADR-020: Offline tour map with shared target only
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Render an operator-imported PMTiles archive locally with MapLibre. The guide may place one target pin and transmit only that target's latitude, longitude, label, version, and visibility. Each phone may use its own position and heading locally to render itself, distance, and direction, but those values are not protocol fields and never leave the device.
**Context**: The guide needs to point guests toward a landmark without Internet access or sharing any participant's location. A live map service would violate the offline requirement, while sending participant positions would violate the product privacy rule.
**Options**: (a) online map and shared positions, (b) offline map with all positions shared, (c) offline map with one shared target and device-local guidance.
**Rationale**: A preloaded regional archive works without Internet. Encoding only `TargetSnapshotPayload` makes the privacy boundary executable and testable. A guest can still see the target without granting location permission; permission adds only local distance and direction.
**Consequences**: The operator must import a suitable `.pmtiles` region pack before the tour. Map styles reject remote resources. Map archives use the reliable asset lane and content-addressed cache. No device location, location history, accuracy, or derived movement may be added to the wire protocol without replacing this ADR.

## ADR-021: Magnetic pointer uses local headings
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: The guide transmits only a state version, magnetic reference, selected bearing angle, and visibility state. Each guest subtracts its own locally sampled magnetic heading to rotate the pointer. Guide and guest heading samples, accuracy, and sampling timestamps remain local.
**Context**: A landmark pointer must work offline and should not require participant locations. True-north conversion would introduce location dependency without improving the current directional-assistance requirement.
**Rationale**: Magnetic-relative guidance is consistent for a co-located tour group and keeps the wire payload small. Sensor accuracy is exposed in the UI so the app can avoid implying precision near magnetic interference.
**Consequences**: The pointer is directional assistance, not surveying or AR anchoring. It may be hidden when heading data is invalid. Device heading and location remain outside the protocol.

## ADR-022: Platform audio lifecycle with no Google Nearby runtime
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Declare the iOS audio background mode and keep Android guide capture or guest playback inside a typed foreground service. Remove the unused Google Nearby Connections dependency from the Android runtime graph.
**Context**: Tour audio must continue when the screen locks. The working cross-platform path uses local IP; retaining an unused Nearby dependency adds Play Services availability and telemetry exposure without serving the active transport.
**Rationale**: Background audio is a legitimate core product behavior on both platforms. Native lifecycle mechanisms make it explicit to the OS and user. Removing Nearby keeps the shipping path local and dependency-minimal.
**Consequences**: Android shows an ongoing tour-audio notification while broadcasting or listening. The iOS app contains `UIBackgroundModes = audio` and a privacy manifest declaring no tracking or collected data. Wi-Fi Aware remains an isolated lab, not the production session transport.

## ADR-023: Per-tour mutual authentication on every session lane
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Generate a random 10-character unambiguous tour code when the guide creates a session. Derive a session-bound key with HMAC-SHA256, then perform a fresh nonce-based mutual proof before admitting a guest on realtime, control, or asset sockets. Bind each proof to the session, guide, participant, requested lane, role, platform, capabilities, and display name as applicable. Compare proofs without early exit.
**Context**: Bonjour/NSD discovery proves reachability, not permission to join. A nearby stranger must not receive audio, content, or state merely because the session is discoverable.
**Options**: (a) trust discovery proximity, (b) approve each guest manually, (c) use a per-tour short code with challenge-response authentication.
**Rationale**: One code scales to a tour group without guide-side approval taps. Nonces prevent replay, lane binding prevents proof reuse across sockets, and deterministic Swift/Kotlin fixtures prove both implementations derive identical results.
**Consequences**: The code is displayed to the guide and entered by guests. Credentials exist only for the active session and are cleared when it ends; they are not persisted to preferences. The handshake authenticates admission but does not itself encrypt application payloads.

## ADR-024: PMTiles v3 is the accepted offline archive
**Date**: 2026-08-21
**Status**: Accepted for local raster and vector sources.
**Decision**: Accept only a complete PMTiles v3 archive plus a MapLibre style version 8 document with exactly one `getoverhere://map-archive` source. Resolve that source to an app-owned `pmtiles://file:///...` URL, reject network glyph, sprite, source, and tile resources, and validate all header sections before rendering.
**Context**: A magic-prefix-only fixture proved nothing about archive structure or renderer support. Android also requires the documented three-slash local file URL; Java `File.toURI()` produces a one-slash form when interpolated directly.
**Rationale**: PMTiles provides a single content-addressable regional file with byte-range access and native MapLibre support on both platforms. Complete archive validation fails before the renderer sees malformed offsets or unsupported metadata.
**Consequences**: The test suite contains a complete one-tile PMTiles v3 archive, validates rejection cases, and renders it through MapLibre. Operator map packs must keep every referenced resource local; remote resource fallback is a hard error.

## ADR-025: Runtime permissions are requested at the feature boundary
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Start local-LAN discovery without requesting microphone, location, or Wi-Fi Aware access. Request microphone access only when a user creates a guide session, location only when map guidance is opened, and `NEARBY_WIFI_DEVICES` only when the experimental Wi-Fi Aware lab is opened. Disable Android application backup.
**Context**: The Android app previously requested microphone and Wi-Fi Aware permissions at launch from every participant, including guests who never transmit audio or use the lab. Its default backup configuration also permitted app-owned tour content to leave the device through platform backup.
**Rationale**: A permission prompt should correspond to the action the user just selected. Guests need no microphone access, and local tour assets are reproducible operator content that should not enter cloud backup.
**Consequences**: Denial is shown as an explicit feature error. The core local-LAN session starts without dangerous runtime permissions; only active feature roles request their required access.

## ADR-026: Android tour runtime is application-owned
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Own `NetworkCoordinator`, `ChannelService`, audio, content, guidance, and application coroutine lifetime in `ComeOverHereApp`. Activities obtain the existing runtime and never end a tour from `onDestroy()`.
**Context**: Android destroys and recreates `MainActivity` for configuration changes. Activity ownership made rotation terminate the guide or guest session even though the process and foreground audio service remained valid.
**Options**: (a) disable Activity recreation, (b) retain selected objects manually, (c) make the process-level application own the tour runtime.
**Rationale**: A tour session outlives a screen instance. Application ownership matches the foreground service and socket lifetime without hiding normal Android lifecycle events.
**Consequences**: Explicit user actions end sessions. Activity recreation only replaces UI state collection. A connected-device instrumentation test must continue proving that the same `ChannelService` survives `ActivityScenario.recreate()`.

## ADR-027: Experimental transports do not raise the production OS baseline
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Support iOS 17 and later for the production app and `TourSessionCore`. Isolate Wi-Fi Aware types and UI behind iOS 26.4 availability checks.
**Context**: Adding the Wi-Fi Aware lab initially changed the entire app and local package deployment target to iOS 26.4, excluding otherwise compatible phones from the working local-LAN product.
**Rationale**: The shipping audio, presentation, map, and pointer features use APIs available on iOS 17. An optional experiment must not dictate the minimum OS for unrelated production behavior.
**Consequences**: Older supported devices receive an explicit lab-unavailable screen while retaining the complete local-LAN tour experience. The reusable verifier rejects deployment-target drift from iOS 17.

## ADR-028: Guide-selected shared screen is explicit session state
**Date**: 2026-08-21
**Status**: Accepted.
**Decision**: Add the versioned GOH2 `visualFocusSnapshot` control message in protocol 2.1. Its three values select Slides, Map, or Pointer. The guide publishes it when changing tools, and each late join or reconnect receives it after the presentation, target, and bearing snapshots so the final foreground choice is deterministic.
**Context**: Target and bearing snapshots reached guests correctly, but a previously visible slide remained in front because the UI inferred visual priority independently on each platform. That made Map and Pointer appear unsent and produced different results for live changes and late joins.
**Options**: (a) keep slide-first UI inference, (b) infer priority from whichever payload arrived last, (c) transmit the guide's selected screen explicitly.
**Rationale**: Screen selection is product state, not transport arrival order. A nine-byte versioned payload is smaller and more deterministic than duplicating precedence rules in SwiftUI and Compose.
**Consequences**: Guests may still browse locally until the next guide change. Existing slide, target, and bearing values remain intact when another tool is foregrounded. Swift and Kotlin exact-byte, stale-state, socket, late-join, and UI tests cover the new message.

## ADR-029: LAN floor with Wi-Fi Aware and bounded BLE no-AP routes
**Date**: 2026-08-22
**Status**: Accepted direction; implementation and capacity claims remain gated by `NextSession.md`.
**Decision**: Keep the existing local-LAN transport as the guaranteed first-class full-capability floor. Use native cross-platform Wi-Fi Aware as the preferred direct no-AP high-bandwidth route and add a bounded BLE controlled-relay overlay for universal discovery, authentication bootstrap, authoritative control state, membership, and gated degraded compressed live voice. Select a route per participant and deduplicate overlapping delivery with stable session, stream, participant, and sequence identifiers. Do not promise AP-less audio for every supported phone.
**Context**: A portable access point has unacceptable setup and power friction. Android LocalOnlyHotspot/Wi-Fi Direct was unstable on the target device. The target device class successfully transferred files through a separate cross-platform AirDrop-like application, making direct Wi-Fi Aware credible. The current GetOverHere iOS production code does not create an Aware listener or browser; only the lab does. The production floor is iOS 17, so many guests will not support Apple's newer Aware stack. The public-domain bitchat iOS and Android sources demonstrate protocol-compatible BLE controlled flooding and live compressed voice, but not this product's capacity or latency requirements.
**Options**: (a) require a portable access point, (b) depend on Android-hosted Wi-Fi, (c) use Aware only and lose unsupported guests, (d) use Aware primary plus LAN and bounded BLE fallback, (e) bridge Apple peer-to-peer Wi-Fi and Android Wi-Fi Direct.
**Rationale**: Option (d) avoids an unstable Android hotspot, preserves the proven full-bandwidth floor, and gives every supported phone a common discovery/control path. BLE voice is treated as expiring realtime traffic with measurable limits, not as proof that BLE can carry arbitrary assets or an unbounded mesh. Platform-specific Wi-Fi islands are not interoperable data paths and are not bridged.
**Consequences**: Wi-Fi Aware remains outside production until both physical role directions pass the isolated probe, which is limited to four focused sessions or two engineering days. BLE mesh routing is deliberately narrow: one authoritative guide, authenticated current-session packets, bounded TTL and fan-out, split horizon, deduplication, rate limits, successor recovery, and no store-and-forward. BLE voice receives an equal physical field gate because it will be the common AP-less route for Aware-ineligible guests. If Aware or BLE voice fails its gate, that route does not ship; LAN remains fully supported. Full slides and PMTiles prefer Aware/LAN or preloaded content.

## ADR-030: Application payloads require end-to-end encryption
**Date**: 2026-08-22
**Status**: Implemented on the production LAN lanes; multi-route delivery remains part of P6.
**Decision**: Encrypt realtime, control, and asset payloads at the application layer with keys derived from the per-tour credential. Bind every authenticated-encryption operation to the session, sender, lane, message kind, sequence, and route-independent frame identity. Link-layer BLE, Wi-Fi Aware, or LAN encryption does not replace this requirement.
**Context**: ADR-023 authenticates admission but explicitly leaves current GOH2 application payloads in plaintext. Multiple radios and relays increase the number of devices and links that can observe traffic. The product carries guide audio, slides, map content, and target state and claims a privacy-first local design.
**Options**: (a) rely on link encryption, (b) add TLS separately to each connected socket, (c) add route-independent authenticated encryption to GOH2 payloads.
**Rationale**: Route-independent authenticated encryption preserves confidentiality and integrity when the same logical message moves over Aware, LAN, BLE, or more than one route. It also prevents a BLE relay from reading or modifying forwarded application content.
**Consequences**: Encryption happens once when the logical frame is created. A sealed frame is immutable and the same encoded bytes are reused across Aware, LAN, BLE, retries, and overlapping delivery; socket writers never encrypt or allocate nonces. Nonces are derived from the key and immutable route-independent frame identity. Reusing an identity with different plaintext is rejected before encryption. Nonces and replay windows become cross-platform wire contracts with exact Swift/Kotlin fixtures. Keys, nonces, credentials, plaintext payloads, and participant location remain absent from logs. Legacy plaintext sessions cannot interoperate with the encrypted protocol version.

## ADR-031: Aware capacity overflow is routed per participant
**Date**: 2026-08-22
**Status**: Accepted product behavior; implementation is part of P6.
**Decision**: Never exceed the guide device's reported current Aware resources. An overflow guest tries authenticated LAN, then BLE voice if P5 passed, then explicit BLE control-only participation with audio unavailable. Existing Aware guests are not evicted to admit overflow. The guide sees connected and audio-ready counts; transport diagnostics remain hidden.
**Context**: The target Pixel reports eight maximum NAN data paths, and vendor APIs expose device/runtime capacity rather than a universal group limit. A tour can exceed that capacity even when discovery and protocol behavior are correct.
**Options**: (a) reject the overflow guest, (b) evict or rotate existing Aware peers, (c) route overflow per participant, (d) exceed the reported limit and rely on runtime failure.
**Rationale**: Option (c) preserves stable listeners, uses the best validated route available to each guest, and makes degraded service explicit. It also lets mixed-route tour capacity exceed a single device's Aware fan-out without pretending Aware itself supports that count.
**Consequences**: Capacity-minus-one, capacity, and capacity-plus-one are mandatory gates. A control-only participant is not counted as receiving audio. Supported tour size and supported Aware-direct size are separate measured claims.

## ADR-032: V1 has session-wide revocation only
**Date**: 2026-08-22
**Status**: Accepted limitation.
**Decision**: V1 does not individually evict or rekey one admitted guest during a live tour. Possession of the current tour code grants session membership. If the code leaks or a participant must be revoked, the guide ends and restarts the tour, which rotates the code and all derived keys.
**Context**: The QR/short-code credential is shared by the tour group. Individual mid-tour revocation requires per-participant key distribution and rekeying that is not otherwise required for v1.
**Options**: (a) add individual rekeying now, (b) accept session-wide restart as the v1 revocation boundary, (c) provide a cosmetic kick without rotating keys.
**Rationale**: Option (b) is explicit and secure within the stated limitation. Option (c) would falsely imply that a guest who retains the session secret can no longer decrypt traffic.
**Consequences**: The guide UI and product documentation must not claim individual eviction. A future protocol version may add participant-specific key wrapping and group rekey without changing the v1 rule retroactively.

## ADR-033: Encrypted GOH2 is an explicit protocol-version break
**Date**: 2026-08-23
**Status**: Accepted P3 contract.
**Decision**: Increment the GOH2 protocol major for encrypted application frames. Decode exposes the local and remote major in a typed compatibility error. Every LAN/Aware/BLE transport maps that error to an explicit version-mismatch event, and the product UI tells the user to update the older build. It must not report the failure as discovery, authentication, or radio loss.
**Context**: ADR-030 prohibits legacy plaintext interoperability. The existing decoder already rejects another major, but transport call sites collapse decode failures into generic connection errors. That makes a deliberate protocol break look like another network failure.
**Options**: (a) silently close legacy peers, (b) accept plaintext as fallback, (c) reject with a typed compatibility state.
**Rationale**: Option (c) keeps the no-plaintext invariant and makes the expected upgrade failure diagnosable. An already-shipped old build cannot be taught the new message, but every new build can identify a legacy inbound frame and expose the correct local state.
**Consequences**: Swift and Kotlin require exact tests for legacy-major rejection and the transport-to-product error mapping. No compatibility shim or plaintext downgrade is allowed.

## ADR-034: Native realtime codecs use canonical PCM16 frames
**Date**: 2026-08-26
**Status**: Accepted P3 implementation contract; physical-device qualification remains pending.
**Decision**: Feed platform-native Opus or AAC-LC encoders with 16 kHz mono signed PCM16 little-endian frames. Prefer 20 ms Opus at 20 kb/s and retain 64 ms AAC-LC at 16 kb/s as the negotiated native fallback. Carry codec-specific configuration bytes in the encoded-audio payload, accumulate arbitrary capture chunks into exact codec frames, and bound receiver reordering by both target and maximum frame counts.
**Context**: The previous audio path sent 16 kHz mono Float32 PCM directly over TCP. Native codec decoders may require magic-cookie or codec-specific data, and capture callbacks do not guarantee codec-sized chunks.
**Options**: (a) retain Float32 PCM, (b) add libopus, (c) use native codecs with a canonical PCM16 boundary and codec-specific configuration.
**Rationale**: Option (c) removes the raw-wire bandwidth problem without adding a dependency and keeps the Swift/Kotlin transport contract codec-neutral. PCM16 is the native Android capture/playback representation and is directly supported by Apple's converter stack.
**Consequences**: Simulator/emulator roundtrips prove API integration only. Physical targets must still prove codec availability, quality, latency, thermal behavior, and background operation before P3 passes. Unsupported native Opus negotiates AAC-LC explicitly; there is no silent raw-PCM fallback.

## ADR-035: Unqualified audio transports fail closed
**Date**: 2026-08-27
**Status**: Accepted and implemented.
**Decision**: A compiled transport that cannot consume the encrypted GOH2 v3 realtime format must reject audio explicitly. It may not retain a raw or plaintext compatibility path. Wi-Fi Aware control and asset lanes use the same sealed frame contract as LAN; Wi-Fi Aware audio remains disabled until the route-neutral producer can hand it the already-sealed frame. The retired Multipeer audio implementation cannot transmit.
**Context**: Migrating the active LAN transport was insufficient for the source-level security invariant. Dormant Wi-Fi Aware and Multipeer implementations still contained raw-audio write paths that could become reachable through a future selection change.
**Options**: (a) leave dormant plaintext paths compiled, (b) duplicate encoding and encryption inside each radio writer, (c) seal supported lanes and fail closed where route-neutral integration is not complete.
**Rationale**: Option (c) prevents downgrade and nonce divergence without pretending the production Aware connection owner exists. Encryption remains a frame-creation responsibility, not a socket-write responsibility.
**Consequences**: `scripts/verify_no_plaintext_session_paths.sh` rejects plaintext envelope decoding, direct raw audio writes, missing seal/open operations in production payload transports, and accidental reachability of retired wrappers. P1/P2 must integrate Aware audio through a shared pre-sealed frame owner rather than re-encrypting per route.
