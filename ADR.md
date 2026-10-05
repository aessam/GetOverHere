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
**Status**: Historical admission UX superseded by ADR-052: open rooms are intentional, with optional editable locking and a hidden media credential. Lane authentication remains; key derivation and payload confidentiality were subsequently updated. The original context below records the earlier decision, not current onboarding requirements.
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

## ADR-036: Discovery availability is not session authority
**Date**: 2026-08-28
**Status**: Accepted and implemented.
**Decision**: Treat Bonjour/NSD removal as `channelUnavailable`, not as a terminal session event. An active guest retains its session credential and reconnect state through discovery loss. Only an authenticated GOH2 v3 `leave` frame from the connected guide ends the remote session and clears guest state. The guide flushes that terminal frame before closing its control transport.
**Context**: Service-discovery records can disappear because of multicast loss, roaming, backgrounding, or interface changes while the authenticated data session remains valid. The previous control planes synthesized `channelEnded` directly from unauthenticated service loss, bypassing reconnect and deleting the credential.
**Options**: (a) continue treating discovery loss as terminal, (b) retain the active session until an authenticated terminal frame arrives, (c) add a separate unauthenticated grace-period timer that can erase the session.
**Rationale**: Discovery locates a peer; it cannot prove that the authenticated guide ended the tour. Option (b) preserves reconnect and makes terminal authority cryptographic instead of observational.
**Consequences**: Inactive discovered channels are still removed from the browse list. Active sessions may show temporarily unavailable while reconnecting, but are not erased. Legacy discovery-originated `channelEnded` events are treated as unavailable. Socket tests require the authenticated terminal frame to arrive before immediate guide shutdown.

## ADR-037: Minor versions are authenticated and replay windows are monotonic per stream
**Date**: 2026-08-28
**Status**: Accepted and implemented.
**Decision**: Preserve the received encrypted-envelope minor version, authenticate that exact byte as AAD, and expose it on the opened logical envelope. Enforce replay protection independently for each `(session, sender, stream)` with a monotonic highest sequence and a bounded sliding window. A previously accepted sequence older than the window is rejected, not reopened after digest eviction.
**Context**: The decoder discarded the received minor byte and reconstructed AAD with the local constant, so a compatible future minor frame failed as generic authentication failure. Replay protection was a global FIFO of digests; once an accepted identity was evicted, the same valid ciphertext was accepted again as new.
**Options**: (a) retain local-version AAD and FIFO digests, (b) authenticate the wire version and add per-stream sequence windows, (c) reject every non-current minor as a major-version break.
**Rationale**: Minor versions are intended for compatible evolution and must remain part of the authenticated wire contract. Per-stream sequence windows preserve bounded reordering while retaining a permanent monotonic floor for the lifetime of the opener.
**Consequences**: A newer compatible minor can be opened only when its exact header authenticates. Modifying the minor byte fails AEAD. Replays below the floor produce an explicit security error. Swift and Kotlin tests cover future-minor preservation, minor tampering, in-window reordering, duplicates, and post-eviction replay.

## ADR-038: Relayed guide frames require asymmetric source authentication
**Date**: 2026-08-28
**Status**: Accepted prerequisite for P4; no relay route may ship before implementation and verification.
**Decision**: The guide creates an ephemeral P-256 signing key for each tour. At logical-frame creation it signs the complete immutable sealed envelope once, and every route reuses that signed frame. Guests pin the guide verification key from the tour QR. A manual-code guest must first authenticate a direct guide connection and pin the same key before it may accept relayed traffic. Relays can verify and forward guide frames but cannot mint them. P4 does not relay guest-authored application frames; future guest relay requires guide-issued participant certificates and a separate decision.
**Context**: GOH2 v3 application encryption uses a session-wide symmetric key derived from the shared tour code. On direct LAN sockets, the transport binds `senderID` to the authenticated peer, so a guest cannot inject a guide frame over its own connection. A relay intentionally delivers a guide-originated frame over a guest-owned link, removing that containment. Any admitted guest knows the symmetric key and could otherwise create ciphertext declaring the guide's sender ID.
**Options**: (a) declare all admitted guests trusted to impersonate the guide, (b) distribute another shared guide MAC key to guests, (c) sign guide-originated sealed frames with a guide-only asymmetric key.
**Rationale**: Another shared secret gives every verifier the ability to forge. A signature preserves encrypt-once/route-many behavior, survives arbitrary forwarding, and keeps signing authority only on the guide device.
**Consequences**: The signed relay wrapper, raw P-256 signature representation, QR descriptor, direct-bootstrap pinning, and cross-platform verification bytes must be specified and tested before P4 forwarding begins. Signature verification occurs before decrypt/apply. A relayed frame with no signature, the wrong pinned key, a changed sealed byte, or a changed signature is rejected. P4 cannot silently fall back to symmetric sender trust.

## ADR-039: Blocking socket I/O uses dedicated workers and per-peer bounded writers
**Date**: 2026-08-28
**Status**: Accepted and implemented for the production LAN lanes.
**Decision**: Run blocking iOS accept/connect/read operations on dedicated dispatch queues, never Swift cooperative-pool tasks. Give every connected peer an independent bounded writer with an enforced send deadline. Realtime writers keep the freshest bounded frames; reliable control/asset writers disconnect on overflow. Bind socket lifetime and callbacks to a monotonically increasing run generation. Encode and seal iOS realtime audio on its own serial worker before enqueueing the same frame to peer writers.
**Context**: Three accept loops plus per-guest blocking reads could consume the width-limited Swift cooperative pool. Both platforms also serialized every guest write through one queue, so one full TCP buffer stalled the whole tour. Queued iOS closures retained raw descriptors beyond session shutdown, allowing descriptor reuse, and audio encode/seal plus counters crossed MainActor boundaries.
**Options**: (a) retain blocking tasks and one fan-out queue, (b) move immediately to Network.framework/async channels, (c) isolate current POSIX/Java sockets behind dedicated readers, managed lifetimes, and bounded per-peer writers.
**Rationale**: Option (c) fixes the measured architecture defects without replacing the validated wire and handshake stack. It leaves a narrow socket implementation that can later be replaced behind the existing transport interfaces.
**Consequences**: One stalled guest cannot block another. Send timeout or reliable-queue overflow removes only that peer. Realtime encode/seal no longer runs on MainActor. Terminal leave is enqueued to all peers and awaited against one deadline before shutdown. The verifier rejects reintroduction of cooperative blocking tasks or a shared send queue in production LAN transports.

## ADR-040: Transport stop and terminal credential erasure are distinct operations
**Date**: 2026-08-28
**Status**: Accepted and implemented.
**Decision**: `stop()` ends current socket activity while retaining configuration needed by transient reconnect. `clearSession()` stops activity and erases the session credential and derived sealing state. Product-level terminal paths, session replacement, and failed guide startup call `clearSession`; reconnect calls `stop` and then explicitly reconfigures its lanes.
**Context**: Audio, control, asset, hybrid, and Wi-Fi Aware transports retained `SessionCredential` after the logical tour ended. Clearing configuration inside `stop()` was not correct because transport startup itself uses `stop()` to reset stale sockets and reconnect intentionally stops active lanes before rebuilding them.
**Options**: (a) retain credentials until transport deallocation, (b) make every stop terminal, (c) distinguish transient transport stop from terminal session erasure.
**Rationale**: Option (c) matches the two existing lifecycle meanings without preserving secrets beyond the tour. A required protocol method makes erasure explicit across every production implementation and test double.
**Consequences**: Ending or replacing a tour removes credentials from active audio, control, asset, hybrid, and Aware implementations on both platforms. A cleared local transport fails explicitly as unconfigured if restarted without a new credential. Reconnect remains possible only because `ChannelService` still owns the admitted credential until the logical session ends.

## ADR-041: Manifest order and identity are the UTF-8 wire bytes
**Date**: 2026-09-03 (fix round 2026-09-02, group G1)
**Status**: Accepted and implemented.
**Decision**: `TourPackManifestPayload` and `AssetManifestPayload` order their entries by `(order, UTF-8 bytes of the ID)` using unsigned lexicographic byte comparison with the shorter prefix first, and reject duplicates by exact UTF-8 bytes on both cores. Swift gains `SessionProtocolError.duplicateSlideID`; Kotlin throws `SessionProtocolException("duplicate slide ID …")`. The CLI describers are generalized to every message kind and print payload enums as decimal raw values, UUIDs lowercased, and every free-form string as lowercase UTF-8 hex (DSCN-21). The guest header on both platforms renders the recorded failure reason, tinted red and allowed to wrap, whenever the connection state is FAILED.
**Context**: Swift `String` comparison, equality, and `Set<String>` use canonical Unicode equivalence, so NFC `café` and NFD `cafe\u{301}` collapsed into one asset. Kotlin `String.compareTo` is UTF-16 code-unit order, so U+1F5FA (`d83d dddf`) sorted before U+FF5E although its UTF-8 bytes (`f0 9f 97 ba`) follow (`ef bd 9e`). The wire carries UTF-8 bytes with neither normalization nor code units. ASCII-only fixtures with unique `order` values could not expose the divergence, and `TourContentStore.swift:95,103` assign `order: 0` to both the map style and the map archive, so ties exist in production today. `AssetManifestPayload` sorted by `order` only with no tie-break and no dedup on either side (DSCN-7). The hello describer already disagreed for an iOS hello (Swift printed `iOS`, Kotlin `ios`), which is why enums now print raw values. ADR-033's typed version error was only half implemented: Swift carried one major, Kotlin plaintext decode threw the base exception, and the guest UI never rendered `tourFeatureError`; this round completes it with `unsupportedMajorVersion(received:supported:)`, the typed Kotlin throw, and one `versionMismatchMessage` builder per `ChannelService`.
**Options**: (a) platform-native string comparison, (b) Unicode collation or normalization before comparison, (c) UTF-8 wire-byte order with exact-byte dedup.
**Rationale**: Option (c) needs no locale tables or normalization, is identical on both runtimes, and compares exactly what is authenticated and transmitted. Option (b) would let two byte-distinct IDs encode as one, which the receiver cannot reproduce.
**Consequences**: Canonically equivalent IDs are distinct assets on the wire. iOS app dictionaries keyed by `String` (`contentStore.sourcesByAssetID` at ChannelDetailView.swift:347 and `assetTransferService.readyURLsByAssetID` at ChannelService.swift:493) still use canonical equivalence and would collapse two IDs the wire treats as distinct; no code change this round, recorded as a hazard. A slide manifest with two identical slide IDs now fails construction instead of encoding silently. Kotlin `AssetManifestPayload` is no longer a data class; its `assets` property is canonical after construction like `TourPackManifestPayload`. The `state` fixture now carries two slides and two tour-pack assets that share an `order` plus an `assetChunk` envelope; new `handshake` and `realtime-fixture` CLI commands pin authChallenge, welcome, leave, and the sealed realtime audioFrame. `scripts/verify_tour_session.sh` compares those bytes, cross-decodes state, handshake, realtime, and audio in both directions, checks each manifest element for `efbd9e` before `f09f97ba`, and fails on empty CLI output instead of comparing empty against empty. The `decode` and `decode-encrypted` output format changed; only the two CLIs and the verifier consume it, and G6's CI parity runs at HEAD. The sealed realtime golden depends on `fixtureCredential` and the sealed major, so G2 regenerates it with the other sealed goldens.

## ADR-042: Tour codes are stretched with PBKDF2-HMAC-SHA256 and sealed GOH2 is major 4
**Date**: 2026-09-03 (fix round 2026-09-02, group G2)
**Status**: Accepted and implemented (DSCN-1, DSCN-8, DSCN-20). Amends ADR-030.
**Decision**: Derive the session credential as `HMAC-expand(PBKDF2-HMAC-SHA256(password = normalized 10-character code as ASCII, salt = sessionID wire bytes (16) || "GetOverHere/GOH4/credential-salt/v1", 600,000 iterations, 32 bytes))`; the expansion label `"GetOverHere/GOH2/session-key/v1" || 0x01` is unchanged. Increment `SealedSessionEnvelope` major 3 → 4 on both cores; majors 2 and 3 are rejected as version mismatch through the ADR-033/ADR-041 path with no plaintext or major-3 downgrade. Native providers only: CommonCrypto `CCKeyDerivationPBKDF` on Apple, `javax.crypto` `PBKDF2WithHmacSHA256` (SunJCE on the JVM, BouncyCastle on Android API 26+). The iteration count, salt label, and output size are wire-contract constants (`SessionCredential.stretchIterations`/`STRETCH_ITERATIONS`, `stretchSaltLabel`/`STRETCH_SALT_LABEL`, `stretchedKeySize`/`STRETCHED_KEY_SIZE`) pinned by known-answer tests on both cores, including one that proves normalization happens before the stretch (`derive("23456-789 ab").key == fixtureCredential().key`). A CommonCrypto failure throws `SessionSecurityError.keyStretchFailed(status)`; a missing JVM provider propagates unwrapped.
**Context**: FND-7. The code space is 32^10 = 2^50 ≈ 1.1×10^15. The salt (sessionID, which is the Bonjour service name, plus a fixed label) is public and only prevents cross-session precomputation; a passive LAN capture of one handshake enables offline guessing. Before: one HMAC-SHA256 per guess; at ~10^10 HMAC-SHA256/s on one RTX-4090-class GPU that is ~1.1×10^5 s ≈ 1.3 GPU-days exhaustive (~0.65 expected). After: 6×10^5 iterations per guess ≈ 6.8×10^20 iterations; at ~7×10^9 PBKDF2-HMAC-SHA256 iterations/s per such GPU that is ~9.7×10^10 s ≈ 3,000 GPU-years exhaustive (~1,500 expected); at a conservative 3.5×10^9/s, ~6,000 GPU-years. Code entropy is unchanged at 50 bits; the entropy fix is the spec's QR path with a 128-bit secret, deferred by DSCN-1.
**Options**: (a) QR 128-bit secret now, (b) PBKDF2 stretch with native primitives, (c) memory-hard stretch (scrypt/Argon2, a new dependency on Android), (d) accept the bound.
**Rationale**: Option (b) raises the offline cost by ~6×10^5 with dependency-free primitives on both platforms and keeps the manual code UX. Option (c) needs a library the JVM/Android floor lacks natively. Option (a) is still required and tracked separately. DSCN-8 held 600,000 iterations because the measured emulator derive (1,545 ms on `GetOverHere_API_36`, arm64, API 36) is under the 3 s rework threshold; the simulator derive measured 0.150 s.
**Consequences**: Amends ADR-030: its confidentiality claim is bounded by the 50-bit code entropy and the PBKDF2 offline-guessing cost recorded here until the QR 128-bit credential ships. `derive()` is now user-visible work, so both apps run it off the main thread (iOS `@concurrent` static hop, Android `withContext(Dispatchers.Default)`) inside the named helpers `startGuideSession`/`startGuestSession`, and every continuation is guarded by the monotonic `sessionAttempt` (DSCN-20; incremented in `createChannel`, `joinChannel`, `leaveChannel`, and `stopCurrentActivity`) so a stale stretch cannot start a session the user has since ended or replaced. The iOS `audioHostIP` guard runs before the hop so a missing guide address fails without paying for a stretch. The join/create buttons show no progress during the stretch this round. All credential-derived goldens changed on both sides: the encrypted hello fixture, the auth fixture, and G1's sealed realtime fixture (regenerated by running both CLIs and diffing, not by hand); the plaintext hello, audio, handshake (fixed proof bytes), and state fixtures are unchanged. Test wall time grows by roughly one stretch per `derive` call site (about +0.6 s on the Swift core suite, +1.4 s on the Kotlin core suite). ADR-032 session-wide revocation still applies. Legacy major-3 builds cannot interoperate; the guest sees the ADR-041 version-mismatch text. The iOS discovery-driven rejoin at `ChannelService.swift` (`joinChannel` on an `audioHostIP` change) still re-derives; DSCN-11 (G4) replaces it with the stop()+reconfigure path that retains the credential. Physical-device timing on the oldest supported iPhone and the slowest Android target is a P3 item; if Android exceeds ~1.5 s there, the owner revisits the count, which is a wire-constant change that regenerates every credential-derived fixture on both sides.

## ADR-043: The realtime lane stays TCP on the LAN floor this round
**Date**: 2026-09-03 (fix round 2026-09-02, group G3)
**Status**: Accepted and implemented (DSCN-4).
**Decision**: Guide-to-guest realtime audio keeps the authenticated, sealed TCP lane on port 50000. Every realtime socket disables Nagle at creation on both platforms (`TCP_NODELAY` on the accepted and the connecting descriptor in `UDPAudioPlane.swift`; `tcpNoDelay = true` on both sides in `UDPAudioPlane.kt`), and `scripts/verify_tour_session.sh` fails when either literal disappears. No UDP work in this round.
**Context**: `NextSession.md` P3 (line 114) said datagrams where supported, and P3 chose TCP. The measured defects were not the transport: Nagle plus delayed ACK batched ~150-byte frames sent every 20 ms (the control lanes already set `TCP_NODELAY`, the realtime lane set only `SO_REUSEADDR`/`SO_RCVTIMEO` on iOS and used default sockets on Android), and playout was driven by frame arrival (ADR-045). Every physical and simulator gate for admission, sealing, ordering, and reconnect is validated on TCP.
**Options**: (a) UDP now with a new admission, ordering, and replay contract, (b) TCP with `TCP_NODELAY` and clock-driven playout, (c) defer both.
**Rationale**: Option (b) removes the two measured latency sources without reopening the handshake and sequencing contracts before the P3 physical measurements exist. Option (a) would also break ADR-023 admission and ADR-030 replay windows on a lane that has no physical measurement yet.
**Consequences**: `TCP_NODELAY` is mandatory on realtime sockets and audited; both transport tests read the option back (`getsockopt` != 0 on iOS, `Socket.tcpNoDelay` on Android). Head-of-line blocking after a lost segment remains and is a P3 physical measurement item (mouth-to-ear over 30 minutes, jitter depth, short-write counts). ADR-039's per-peer bounded writers still bound the guide's send side.

## ADR-044: Audio-lane loss is a reconnect trigger with the same authority as control-lane loss
**Date**: 2026-09-03 (fix round 2026-09-02, group G3)
**Status**: Accepted and implemented (FND-1, DSCN-10, DSCN-19).
**Decision**: The guest realtime transport emits exactly one `AudioSessionEvent.failed` / `AudioSessionEvent.Failed` per run when the lane is lost, and `ChannelService` routes it through the existing control-lane handler on both platforms. iOS messages: `Guide audio connection closed` (post-authentication EOF or an invalid sealed frame), `Guide audio connection failed` (invalid address or refused connect), `Guide audio socket failed` (no descriptor), `Guide audio handshake did not complete` (handshake EOF or the 5 s receive timeout), `Native audio decode failed`; Android: `Guide audio connection lost (<exception simple name>)` and `Native audio decode failed`. Nothing is emitted on a local `stop()`, after a `.versionMismatch`, or for a pre-authentication credential or protocol rejection. iOS keeps `pendingAudioLaneFailure` for a loss observed while the control lane is still `.connecting` or `.reconnecting` and schedules the reconnect when `.connected` arrives; Android already routes `Failed` while `CONNECTING` through `failCurrentGuestRoute`. Five consecutive audio-lane failures without a delivered PCM buffer end the guest session as FAILED with `Audio connection lost repeatedly` (`failGuestSession`, DSCN-19); the counter resets on the first PCM buffer of a run and in `stopCurrentActivity()`, never on control-lane `.connected`.
**Context**: The guest audio handler was set to nil (`ChannelService.swift` `startGuestTransports`, `ChannelService.kt:710`) and the read-loop exit only logged, so a guest whose realtime socket died stayed CONNECTED and mute until the control lane also failed. On iOS `.connected` cancels the reconnect task, so an audio connect refusal during startup (guide audio port not yet listening) followed by the control handshake would have produced a CONNECTED guest with no audio lane and no retry (G3 critique major). Wrong-code semantics: on both lanes the guest opens the guide's sealed challenge with its own credential before sending hello (`UDPAudioPlane.swift` `authenticateGuide`, `UDPAudioPlane.kt` `authenticateGuide`, `LocalSessionControlTransport` likewise), so a wrong tour code surfaces at the guest as `SessionFrameSecurityError.authenticationFailed` / `SessionFrameSecurityException`, never as an incomplete handshake or EOF; the guide sees an incomplete handshake and closes. Audio-lane credential rejection is therefore log-only (the control lane reports admission; G4 FND-8 maps only the AEAD failure to `credentialRejected` there), and the tests assert that a wrong code produces no `.failed` on the audio lane.
**Options**: (a) control-lane-only reconnect, (b) an audio-lane heartbeat with its own reconnect path, (c) route audio-lane loss into the existing control-lane handler with run-generation guards.
**Rationale**: A mute CONNECTED guest is a product failure. Option (c) keeps one reconnect authority, one dedupe guard (`reconnectTask == nil` / `reconnectJob != null`), and one attempt counter; the transport-level run guards (iOS `!socket.isCancelled` captured before `close()`, Android `isRunActive(epoch)` plus `emitFailedOnce`) prevent a stale run from disturbing the run that replaced it, which matters because the reconnect body calls `stop()` and `startListening` back-to-back.
**Consequences**: Post-authentication loss, connect failure, handshake EOF/timeout, and native decode failure all schedule the ADR-034 exponential reconnect; a decode failure also cancels the socket so the read loop exits without a second event. The transport tests prove the guide close emits, a local stop stays silent, and a wrong code stays silent on both platforms; the instrumented `AudioLaneReconnectTest` proves the Android `ChannelService` reaches RECONNECTING through real NSD discovery. The iOS `ChannelService`-level proof is deferred to G4: `channels` is filled only by Bonjour discovery, `scheduleReconnect` needs `activeChannel`, and the DSCN-23 injection seam (`NetworkCoordinator.init(displayName:controlPlane:audioPlane:)` with `LifecycleControlPlane.emit`) belongs to G4. After `failGuestSession`, `listenState` stays `.listening` and `activeChannelID` stays so the failed channel remains on screen; a late audio event converges because `stopCurrentActivity()` erased `guestCredential`.

## ADR-045: Realtime playout is clock-driven with silence concealment
**Date**: 2026-09-03 (fix round 2026-09-02, group G3)
**Status**: Accepted and implemented (FND-3, FND-5, DSCN-5).
**Decision**: A per-frame-duration timer (`DispatchSourceTimer` on the `audio.tcp.playout` queue; `ScheduledExecutorService` thread `goh2-audio-playout`) calls `EncodedAudioJitterBuffer.popForPlayout(nowNanoseconds:)`, which returns `.frame`, `.conceal(missingSequence:)`, or `.wait` on both cores (`popReady` is removed). A missing expected sequence while the buffer is below the target depth (60 ms) is concealed with exactly one PCM16 silence frame of `sampleRate * frameDuration / 1000 * channels * 2` bytes (640 bytes for 16 kHz / 20 ms / mono); a gap with the buffer at or above the target depth resyncs to the oldest buffered frame. Native decoders run only on the playout thread; the read loop only offers. A decoder failure is reported once (`onDecodeFailure`) and stops the clock. `TourSessionFixtures.simulatePlayout()` and the `playout` CLI subcommand pin the decision contract to `w,w,f1,f2,w,c3,f4,f10,f11,w` on both sides, gated by `EXPECTED_PLAYOUT` in `scripts/verify_tour_session.sh`. Android encode + seal + fan-out moves off the caller thread onto the `audio-encode-seal` single-thread executor (`BroadcastProcessor`, mirroring the iOS ADR-039 `audio.encode.seal` queue); `sendAudio` is no longer `@Synchronized`. `AudioTrack.write` results are handled: short writes are counted (`playbackShortWriteCount`) and logged (first, then every 100th), negative codes are counted and surfaced once per playback run through `playbackFailureHandler`, which `ChannelService.kt` maps to `tourFeatureError = "Tour audio playback failed (<code>)"`. The iOS capture-tap comment now states the ~100 ms AVAudioEngine floor instead of the requested ~7 ms (DSCN-5, no behavior change).
**Context**: Drain happened only when a frame arrived (`UDPAudioPlane.swift`, `UDPAudioPlane.kt` `popReady` loops), so a lost frame shortened the timeline and silence between bursts was never concealed; the spec's PLC claim was false because native Opus/AAC decoders expose no PLC API. On Android the capture flow was collected on the application's `Dispatchers.Main` scope (`ComeOverHereApp.kt`, `AudioEngine.kt` `flowOn` moves only the upstream), so Opus encoding, sealing, and fan-out ran on the UI thread every 10 ms. `AudioTrack.write(..., WRITE_NON_BLOCKING)` returned a count that was discarded, so a full track buffer or a dead track was invisible.
**Options**: (a) arrival-driven drain, (b) DAC-paced blocking writes, (c) a local timer with silence concealment and resync.
**Rationale**: Option (c) preserves timing from a local clock instead of the network, needs no codec PLC, keeps decoders off the socket thread, and is testable with an injected clock and a manual `tick()` on both platforms. Option (b) would block the read loop on the audio hardware and cannot conceal.
**Consequences**: Documented limitation, not an open question: timer-versus-DAC drift is not corrected. It is bounded on one side by the 250 ms jitter cap (`capacityExceeded` drops) and surfaced on the other by the Android short-write counters; iOS has no backlog metric (`AVAudioPlayerNode.scheduleBuffer` without a completion counter), and P3 physical must add one and record short-write counts, jitter depth, and mouth-to-ear over 30 minutes. `PlayoutClock` is internal on both platforms with an injectable clock; production calls `start()` right after construction and tests never do. The Kotlin `close()` clears the receive thread's interrupt flag before `awaitTermination(500 ms)` so the decoder is not closed under an in-flight decode, and logs when the playout thread does not stop in time. Verifier audits require the `audio.encode.seal`/`audio-encode-seal`, `audio.tcp.playout`/`goh2-audio-playout` labels and reject a `@Synchronized sendAudio`. The cross-platform decision API is a same-patch core change on both sides with identical tests; no wire bytes changed.

## ADR-046: The guide commits and publishes only after every lane and microphone capture are running
**Date**: 2026-09-04 (fix round 2026-09-02, group G4)
**Status**: Accepted and implemented (FND-2, DSCN-23).
**Decision**: Guide-side lane start is synchronous and throwing on both platforms: `SessionControlTransport.startGuide() throws`, `SessionAssetTransport.startGuide() throws`, `AudioPlane.startBroadcasting(channelID:quality:) throws` with `AudioPlaneStartError` (`sessionNotConfigured`, `noNativeEncoder`, `socketFailed`, `bindFailed`, `listenFailed`) on iOS; `IllegalStateException` from `startGuide()`/`startBroadcasting()` on Android; the Android microphone preflight (`RECORD_AUDIO` permission, `AudioRecord` initialization, recording state) runs synchronously inside `AudioEngine.startCapture()` and the returned flow only reads. `startGuideSession` runs control, asset, audio, and capture in that order, then commits state (`channels`, `activeChannelID`, `.broadcasting`, `.connected`, `tourCode`) and publishes the Bonjour/NSD record last. `rollbackFailedGuideSession` on both platforms clears all three lanes, stops capture and guidance, resets state to `.failed`, and broadcasts `.channelEnded` (a no-op unpublish when nothing was published). Test seams (DSCN-23, no behavior change): iOS `AudioEngineInterface` and `NetworkCoordinator.init(displayName:controlPlane:audioPlane:)`; Android `AudioEngineInterface`, `LocalGuidanceInterface`, the `NetworkCoordinator(controlPlane, udpAudio, scope)` primary constructor, and `ChannelService(..., reconnectBaseDelayMillis)`. Production call sites keep the concrete types.
**Context**: iOS appended the channel, set `.broadcasting`, and published Bonjour before the audio lane and capture started, and the rollback never sent `channelEnded`, so every failed simulator `createChannel` left a phantom NetService. Android started the control and asset lanes, then committed `BROADCASTING` and published NSD before the audio lane and capture, and the `SecurityException` from the microphone preflight was thrown inside the collector coroutine where the `try` in `startGuideSession` could not catch it; the catch block never rolled back. Both guides also dropped asynchronous lane `Failed` events because `handleControlConnectionEvent` guards on `listenState == .listening` / `LISTENING`, so an unconfigured lane or a bind failure was invisible to the guide.
**Options**: (a) keep asynchronous `Failed` events and add a guide-side consumer, (b) a startup state machine that waits for every lane's first event, (c) synchronous throwing lane start with commit and publish last.
**Rationale**: "Publish only after all lanes start" is unverifiable unless lane start reports synchronously; option (c) makes the ordering a plain sequence of throwing calls with one catch, testable with fakes on both platforms, and needs no new event plumbing. Option (b) adds a state machine for a problem that is a sequencing bug.
**Consequences**: A guide that cannot bind a lane or open the microphone ends in `.failed` with the error text, no channel on screen, no discovery record, and cleared credentials; `ChannelServiceLifecycleTests`/`ChannelServiceLifecycleTest` prove both the capture-failure and the bind-failure rollback on both platforms and that the audio lane starts before capture. Non-throwing conformers (Wi-Fi Aware lab wrappers, `MultipeerAudioPlane`, test fakes) still satisfy the throwing requirements. The Android `BroadcastProcessor` is constructed after the bind so a bind failure cannot leak its executor (DSCN-28). `LocalSessionTransportTests`/`LocalSessionTransportTest` now assert that an unconfigured `startGuide()` throws and emits nothing.

## ADR-047: Pending handshakes are bounded per lane
**Date**: 2026-09-04 (fix round 2026-09-02, group G4)
**Status**: Accepted and implemented (RSK-1).
**Decision**: Every accept loop (control, asset, and realtime lanes on both platforms) admits at most 32 accepted-but-unauthenticated connections per transport instance. The slot is acquired in the accept loop before the handshake worker is dispatched (`HandshakeSlots` in `SocketFrameIO.swift`, `java.util.concurrent.Semaphore(MAXIMUM_PENDING_HANDSHAKES)` on Android) and released the moment `authenticateGuest` returns or throws, never at read-loop exit. The connection beyond the bound is closed without a single handshake byte and one log line is written (`Session: pending handshake bound reached; closing connection` / `TCP: pending handshake bound reached; closing connection`).
**Context**: Each accepted socket held a 5 s receive timeout, its own dispatch queue or thread, and a sealed challenge write with no cap, so a peer that opened sockets and sent nothing could pin unbounded workers on the guide for 5 s each.
**Options**: (a) rely on the existing 5 s receive timeout, (b) one global bound across lanes, (c) a per-lane bound of 8 as the deep-dive suggested, (d) a per-lane bound calibrated above the largest tour group.
**Rationale**: Option (a) bounds the duration but not the count. Option (b) lets one lane starve another. Option (d) keeps each lane independent and is a two-line change in each accept loop. Option (c) was implemented first and failed the existing 24-guest burst test (`controlLaneScalesBeyondProcessorCount`, `Caught error: .expired` after 8 s): the accept loop dequeues a simultaneous burst faster than the handshakes complete, so with a bound of 8 sixteen legitimate guests were closed, and a whole group reconnecting after a guide restart would have burned ADR-034 backoff attempts across three waves. 32 is above the 24-guest group with margin, still bounds a silent-peer attack to 32 workers for at most 5 s each, and a legitimate slow guest still gets a slot as soon as any pending handshake resolves.
**Consequences**: `HandshakeBoundTests`/`HandshakeBoundTest` prove on both lanes and both platforms that the 33rd silent connection reads EOF while the first still receives the challenge, and that closing one pending peer admits the next; the 24-guest burst test passes unchanged. The integration map named 8; this ADR records the calibrated 32 as the contract (`maximumPendingHandshakes` / `MAXIMUM_PENDING_HANDSHAKES`). Release on the 5 s receive-timeout path is by construction (the same `release()` after `Result`/`finally` covers the timeout throw as it covers the EOF throw) and is not separately tested because it would add more than 5 s per lane per platform to the gate. On Android the `finally` begins at the first statement after the accept loop's `tryAcquire` (`socket.soTimeout = 5_000` is inside it; the realtime lane takes its post-hello `InputStream` after the handshake), because a `SocketException` from those lines on an already-closed socket would otherwise leak one permit for the life of the transport instance (verification finding, 2026-09-04). That sub-millisecond close race cannot be induced deterministically, so the repair is by construction with no separate test. The iOS accept loops use `Result` + `switch` so the slot is released before the version-mismatch and rejection branches run; the `unsupportedMajorVersion` pattern is unchanged.

## ADR-048: Terminal guest failures erase transport credentials, credential rejection never retries, and the guide leave flush is asynchronous
**Date**: 2026-09-04 (fix round 2026-09-02, group G4)
**Status**: Accepted and implemented (FND-8, FND-6 on both platforms per DSCN-11, DSCN-12, DSCN-13, DSCN-20, DSCN-26, DSCN-27).
**Decision**: (1) One terminal path: `failGuestSession(message:)` (introduced by G3) now serves control-lane version mismatch, credential rejection (`"The tour code was rejected. Check it with the guide."`), reconnect exhaustion (`"Could not reconnect to the guide"`), and the DSCN-19 audio cap; it cancels the reconnect, calls `stopCurrentActivity()` (which erases credentials on audio, control, and asset), and leaves `.failed` plus the reason on screen. (2) A wrong tour code is a distinct event: `SessionControlEvent.credentialRejected` / `SessionAssetEvent.credentialRejected` / `TourControlConnectionEvent.credentialRejected` (Kotlin `CredentialRejected`), produced only when the guide's sealed challenge or welcome fails AEAD authentication (`SessionFrameSecurityError.authenticationFailed`; Kotlin the new `SessionFrameAuthenticationException` subtype of `SessionFrameSecurityException`, DSCN-26) or when the guide proof mismatches. An EOF or malformed frame during the handshake stays `.failed` and keeps the reconnect path; the audio lane is unchanged (log-only, ADR-044). (3) End Tour never blocks the main thread: `SessionControlTransport.sendLeave() async` / `suspend fun sendLeave()` enqueues the authenticated leave and waits off the main actor (iOS `session.data.terminal` queue, Android `Dispatchers.IO`) for delivery or the existing 2 s deadline; `TourControlService.endGuideSession()` is `async throws` / `suspend`. `leaveChannel()` ends UI state immediately, broadcasts `channelEnded`, and clears the lanes after the flush only when the dedicated `sessionGeneration` is unchanged, because `TourControlService.configureSession` stops lanes and a `createChannel`/`joinChannel` inside the 2 s window must own them. `sessionGeneration` is bumped only where lane ownership changes: `startGuideSession`/`startGuestSession` immediately before the lanes are configured, `stopCurrentActivity()`, and `leaveChannel()`/`terminate()` after their `activeChannel` guard. The first implementation reused the DSCN-20 `sessionAttempt`, which is also bumped by every no-op `leaveChannel()`/`terminate()` and by `joinChannel`'s early-return guards, so a second End Tour tap inside the flush window disowned the pending teardown and left all three lanes listening with the ended tour's credential (verification finding, 2026-09-04); `endTourTeardownSurvivesANoOpLeave` on both platforms pins the repair. The deferred teardown calls `stopCurrentActivity(discardingPendingStretch: false)`: it clears the lanes without touching `sessionAttempt`, because that leave already invalidated older stretches and a Create/Join started inside the window is the user's newest action; `endTourTeardownDoesNotDiscardAFollowingCreate` pins that on both platforms. Android's deferred flush uses `try`/`catch` that rethrows `CancellationException` (DSCN-27), never `runCatching`, so a cancelled scope does not run `stopCurrentActivity()` inside a cancelled coroutine. (4) iOS termination: `ChannelService.terminate()` uses the synchronous bounded flush (`endGuideSessionBeforeTermination()`), `AppCoordinator.stop()` calls it before `coordinator.stop()`, and `GetOverHereApp` wires `UIApplication.willTerminateNotification`; scene phase `.background` is deliberately not used because a backgrounded guide keeps broadcasting. Android has no termination hook; a process kill relies on ADR-036 reconnect exhaustion at the guests. (5) FND-6 on both platforms: a discovery announce that changes `audioHostIP` for the active channel calls `restartGuestTransports(channel:)` (stop + reconfigure with the retained credential), never `joinChannel`, never `clearSession`, never a fresh PBKDF2 stretch; the reconnect timer uses the same function with the freshest discovered address. (6) DSCN-13: a legacy guest on the guide's audio lane sets `tourFeatureError` only; the transport already closed that connection and the guide's `connectionState`/`listenState` are untouched. The guide's audio-lane `.failed` branch still sets `connectionState = .failed` (RSK-18); that asymmetry is deliberate because it reports the guide's own lane, not one guest. (7) DSCN-12: when iOS capture cannot resume after an interruption or a converter rebuild, the capture stream ends and `ChannelService` surfaces `"Microphone capture stopped"` while the control and asset lanes stay up; Android surfaces the same text when the capture flow throws. No `try?` on any termination path; failures are logged with the error type name only.
**Context**: Version mismatch and reconnect exhaustion set `.failed` without `clearSession`, so credentials stayed inside the transports. A wrong code surfaced as `.failed("Session: invalid welcome: …")` / `Failed("Session: guide connection failed: …")` and both platforms retried it five times (about 31 s) because a credential rejection was indistinguishable from a transport failure. `LocalAuthenticatedSessionTransport.send(kind: .leave)` waited on a semaphore for up to 2 s on the main actor (both classes are main-actor isolated), so End Tour froze the UI. iOS had no termination path: `AppCoordinator.stop()` was never called and stopped only the audio plane. The discovery-driven `joinChannel` on an address change re-ran `stopCurrentActivity` → `clearSession` and a second stretch, violating ADR-036/ADR-040 on both platforms. RSK-3 fixed the premise: the guest opens the guide's sealed challenge with its own credential before sending hello, so only the AEAD failure can mean "wrong code"; matching Kotlin on message text would have classified length, identity-reuse, and replay failures as credential rejections while Swift did not.
**Options**: (a) keep one `failed` event and pattern-match messages, (b) a typed rejection event sourced only from AEAD/proof failures, (c) treat every handshake failure as terminal.
**Rationale**: Option (b) keeps the reconnect authority of ADR-034/ADR-044 for real transport loss, ends the wrong-code retry storm, and is provable with a raw closing server (EOF stays `.failed`) and a wrong-code transport test (`credentialRejected`, no `.failed`). Option (c) would turn a guide restart into a terminal guest failure. The asynchronous flush keeps the ADR-040 delivery deadline without a main-thread wait; the lane-ownership `sessionGeneration` guard is the only ordering primitive needed because `configureSession` already resets the lanes; `sessionAttempt` stays the DSCN-20 stretch guard and is not an ownership signal.
**Consequences**: After `failGuestSession` the guest keeps `listenState == .listening` and `activeChannelID` so the failed channel stays on screen with its reason; `speakerFeedbackWarning` is gated on `connectionState != .failed`; late events converge because `guestCredential` is nil (`scheduleReconnect` returns before mutating state on iOS, `guestCredential ?: return` on Android). `ChannelServiceLifecycleTests`/`ChannelServiceLifecycleTest` prove the terminal paths, the deferred teardown after the leave flush, the address-change reconfiguration, and (iOS, DSCN-28) that audio-lane loss schedules a reconnect both after `.connected` and when it arrives during the control handshake. `GuestHandshakeOutcomeTests`/`GuestHandshakeOutcomeTest` pin EOF as `.failed`. `terminate()` is unit-tested; the `willTerminate` modifier is three lines that a unit test cannot raise and is verified on device by ending the app while broadcasting (P3 physical checklist). The lab-only `WiFiAwareSessionControlTransport.sendLeave()` enqueues without delivery tracking. FND-13 counts live in `TourControlService.connectedGuestCount` (set-keyed by participant, cleared in `stop()`), separate from the audio-lane `listenerCount`; the guide UI shows `"<n> connected · <m> audio"`, and the guest UI shows `speakerFeedbackWarningText` while listening on the loudspeaker. Android requests `AUDIOFOCUS_GAIN` for voice communication and handles `ACTION_AUDIO_BECOMING_NOISY` by forcing private output (`onOutputForcedPrivate` → `listenerOutput = PRIVATE_AUDIO`; focus loss → `"Another app took over audio"`); iOS rebuilds the capture converter on a route or configuration change and pauses/resumes on interruption through the pure `interruptionAction(for:)` / `needsConverterRebuild(current:converterInput:)` decisions, which are unit-tested because the observers need hardware.

## ADR-049: Guest asset transfer is bounded and self-repairing
**Date**: 2026-09-04 (fix round 2026-09-02, group G5)
**Status**: Accepted and implemented (FND-9, DSCN-16, DSCN-17).
**Decision**: (1) The content-addressed cache repairs a length-mismatched `complete/` entry or an oversized `partial/` file by deleting it, writing one stderr line, and reporting it as missing (`nil` from `readyURL`/`readyFile`, offset 0 from `resumeOffset`); a failed delete still throws. `AssetCacheError.lengthMismatch` is no longer thrown and carries a deprecation comment (DSCN-17: it is not on the DSCN-2 deletion list). Kotlin gains `AssetChecksumMismatchException` as a subtype of the now-`open` `AssetCacheException` so the service classifies a checksum failure by type, never by message text. (2) The guest transfer service isolates every asset: a cache error for one asset reports FAILED for that asset and the manifest loop continues. (3) At most `maxInFlightRequests = 2` / `MAX_IN_FLIGHT_REQUESTS = 2` assets have an outstanding request per guest; the rest wait in an ordered pending queue that is refilled when a transfer finishes (READY, FAILED, or expired). The slot is reserved before the cache call so a reentrant pump cannot exceed the cap. Hashes still in flight when a newer manifest arrives keep their slot and are not re-requested. (4) A checksum-mismatched asset is re-requested once from offset 0 (the cache already deleted the partial); the second mismatch sends FAILED with the mismatch detail and releases the slot (`maxTransferAttempts = 2`). (5) DSCN-16: every request arms a per-hash inactivity deadline (`inFlightDeadline = 15 s` / `IN_FLIGHT_DEADLINE_MILLIS = 15_000`, re-armed on every request for that hash, cancelled when the transfer finishes or the queue resets); on expiry the guest reports `Asset <assetID>: no chunk received within 15 s`, sends FAILED with detail `no chunk received within 15 s`, and frees the slot. iOS arms a main-actor `Task`; Android schedules on the same single worker thread (`newSingleThreadScheduledExecutor`, still named `tour-asset-transfer`). The deadline is an init parameter with the contract constant as its default so a test can use 300 ms; production call sites are unchanged. (6) `.disconnected`/`Disconnected` and `stop()` reset the pending, in-flight, attempt, and deadline state; Android routes the `stop()` reset through the worker so FIFO order places it after any handler already running and before every event of the next run. (7) A chunk for a hash that is not in flight is dropped with one stderr line: every chunk follows a request and every request reserves a slot, so the only such chunk is a late answer after the deadline already reported FAILED; the asset recovers on the next manifest or rejoin. (8) iOS `ChannelService` stores an asset-transfer `.failed` message in `tourFeatureError` like Android, and both guest screens render `tourFeatureError` below the speaker warning whenever the connection state is not FAILED (FAILED already renders it in the header, ADR-041).
**Context**: FND-9. `readyURL`/`readyFile` threw a length mismatch into the manifest loop, so one corrupt local entry stopped every later asset from being requested and sent no FAILED status; a checksum mismatch was terminal; the guest requested every missing asset at once against the asset lane's per-peer writer of capacity 8 that disconnects on overflow (ADR-039); iOS logged asset failures without surfacing them, and neither guest screen rendered `tourFeatureError`. The critique showed that a cap without an exit turns an unanswerable request (the guide throws `unknownAssetHash`/`invalidRequestOffset`/`shortRead` and has no guide-to-guest failure frame) into head-of-line blocking; DSCN-16 added the guest-local deadline.
**Options**: (a) keep throwing and catch per asset in the service, (b) cache-side repair with return-value reporting plus a guest scheduler, (c) unbounded requests with a larger writer, (d) a guide-to-guest failure frame (wire change).
**Rationale**: Option (b) is the smallest change that keeps one repair policy in the cache and one scheduler in the service; a cap of 2 keeps at most two 64 KiB chunks queued per guest under the capacity-8 writer; two attempts bound a persistently corrupt source without hiding it; the deadline needs no wire change and covers every unanswered request, including a guide that never answers. Option (d) is deferred because it changes GOH2 bytes for a case the deadline already resolves.
**Consequences**: A corrupt local entry costs one re-transfer instead of a failed pack; a bad or unanswerable asset produces a FAILED status visible to the guide (`Guest asset failure for <hash>: <detail>`) and a `tourFeatureError` on the guest; the guest never holds more than two requests. The loopback tests on both platforms run a four-asset pack with a corrupt complete entry; the recording-transport tests pin the cap, the retry, the second-mismatch FAILED, the disconnect reset, and the deadline release. A slow guide whose chunk lands after the 15 s deadline sees that asset stay FAILED until the next manifest or rejoin. The scheduler is guest-side only; the guide path is unchanged. Audio-relative throttling remains P7. The G5 `disconnectResetsInFlightRequests` and the Android `assetTransferFailureSurfacesInTourFeatureError` tests pass on the pre-G5 tree by construction (no queue existed; Android already stored the message) and are kept as guards. No `TourSessionCore` change and no wire-byte change; all fixture stages of `scripts/verify_tour_session.sh` are unchanged.

## ADR-050: Retired transport code is deleted rather than kept compiled
**Date**: 2026-09-04 (fix round 2026-09-02, group G6)
**Status**: Accepted and implemented (FND-14, DSCN-2, DSCN-25).
**Decision**: Delete the retired iOS files `MultipeerAudioPlane.swift`, `MultipeerTransport.swift`, `WiFiHotspotJoiner.swift`, `LeaderElection.swift`, the `BLETransport`/`CompositeTransport`/`L2CAPAudioStream` stubs, the no-op `TransportMessage.swift` (`extension BLECommand {}`), and `Models/ChannelMessage.swift`; the Android `WiFiHotspotManager.kt`, `LeaderElection.kt`, `DataTag.kt`, `ChannelMessage.kt`, the `BLETransport`/`L2CAPAudioStream`/`NearbyTransport`/`PeerInfo` stubs, the `ChatService`/`FileShareService`/`WalkieTalkieService` stubs, `AppNavigation.kt`, and the chat/files/nearby/walkie-talkie screen stubs with their now-empty directories; and the `com.apple.developer.networking.HotspotConfiguration` entitlement. Keep `BLEControlPlane`/`BLEConstants`, the Wi-Fi Aware lane and lab transports, `HybridSessionTransports`, Kotlin `TransportMessage.kt` (`nowAsSwiftRef()` is referenced by `ChannelService.kt`), the `Logger` chat/fileShare/walkieTalkie categories (not on the DSCN-2 list), and the `CHANGE_WIFI_STATE`/`CHANGE_NETWORK_STATE` permissions (the kept Wi-Fi Aware transports call `requestNetwork`, so they are not "only used by deleted code"). `scripts/verify_no_plaintext_session_paths.sh` replaces its two Multipeer audits with an existence audit over the six retired transport paths and an entitlement audit. CLAUDE.md and AGENTS.md change only the two sentences that named the deleted files (DSCN-25).
**Context**: About 400 iOS and 310 Android lines of unreachable code were compiled into both apps through the synchronized group and the source set (FND-14). The verifier audited `MultipeerAudioPlane.swift` by path with `rg`, which exits 2 on a missing path, so that audit would have passed silently the day the file was removed. The hotspot entitlement had no owner once `WiFiHotspotJoiner` was retired.
**Options**: (a) keep the files compiled behind audits, (b) move them to an excluded directory, (c) delete them.
**Rationale**: Option (c) removes the plaintext-path surface and the ownerless entitlement outright; git history retains the code; an existence audit is the only audit shape that cannot pass on absence.
**Consequences**: Both apps build, lint, and pass their suites without the files and with no pbxproj edit (`GetOverHere` is a `PBXFileSystemSynchronizedRootGroup`). The audit now exits 1 with `retired transport returned: <path>` if any listed file reappears (proved by touching one) and with `hotspot entitlement returned without a hotspot owner` if the key returns. ADR-046's mention of `MultipeerAudioPlane` as a non-throwing `AudioPlane` conformer is historical.

## ADR-051: Core parity runs in CI without app builds, and every gate resolves its toolchain from the environment
**Date**: 2026-09-04 (fix round 2026-09-02, group G6)
**Status**: Accepted and implemented (DSCN-3, DSCN-15, DSCN-24). First hosted parity success: [run 33930529033](https://github.com/aessam/GetOverHere/actions/runs/33930529033), commit `9b02452`, September 4. The original G6 no-push blocker is resolved.
**Decision**: `scripts/verify_core_parity.sh` runs `swift test` on `TourSessionCore`, `:tour-session-core:test` plus `:tour-session-cli:installDist`, builds the Swift CLI product, and byte-compares every argument-free subcommand both CLIs expose at HEAD (`fixture encrypted-fixture audio-fixture handshake realtime-fixture state auth faults playout recovery focus`), printing `ok <command> bytes=N` per subcommand and ending with `Core parity passed`. No xcodebuild, no APK, no lint, no toolchain mutation. `.github/workflows/core-parity.yml` runs it on `macos-latest` for `push` to `main`, `pull_request`, and `workflow_dispatch`, with Temurin 21 (the Android Studio JBR major used locally; Gradle 8.13, AGP 8.13.2, Kotlin 2.2.10 support it) and a step that selects the newest `/Applications/Xcode_26*.app` only when the default `swift --version` is below 6.2 (`Package.swift` is `swift-tools-version: 6.2`); toolchain selection lives in the workflow, never in the script. `verify_tour_session.sh`, `verify_core_parity.sh`, `capture_physical_test.sh`, `repro_visual_focus.sh`, and `verify_wifi_aware_lab.sh` resolve Xcode as `GOH_XCODE_DEVELOPER_DIR`, then `DEVELOPER_DIR` where the script already honored it, then `xcode-select -p`, then the previous literal; and Java as `GOH_ANDROID_JAVA_HOME`, then `JAVA_HOME`, then the JBR literal. The two verifiers print `ANDROID_JAVA_HOME=` and `XCODE_DEVELOPER_DIR=` before their preflights so a run is attributable to its toolchain.
**Context**: No CI existed. The gate hardcoded `/Users/aessam/Downloads/Xcode-beta.app` and the JBR path and ignored `JAVA_HOME`, so it ran on exactly one machine and cross-language byte parity depended on one person remembering a ten-minute script. The runner image may default to an Xcode below the package's tools version.
**Options**: (a) the full gate in CI (simulator plus emulator: slow and flaky on shared runners), (b) core parity only, (c) no CI.
**Rationale**: Option (b) catches the class of regression that matters most (byte-level Swift/Kotlin divergence) in minutes on a plain runner and reuses one script that is runnable locally; the full gate stays local and physical.
**Consequences**: The workflow assumes the image ships an `Xcode_26*.app` and an `ANDROID_HOME` (Gradle configures `:app` for any task); both are confirmed only by the first run, which this round could not trigger because the branch was not pushed (no-push rule). A shell whose `JAVA_HOME` points at another JDK now selects that JDK for Gradle, visibly, and the preflight still fails loudly on absence (`JAVA_HOME=/nonexistent` exits 1 with `error: Java not found under /nonexistent` on both verifiers). The parity list is maintained by hand: a fixture subcommand added to one CLI and not the other fails at the compare, and a new argument-free subcommand must be appended to the loop.

## ADR-052: Open rooms with independently editable admission codes

**Date**: 2026-09-04
**Decision**: New rooms start open. The guide controls `Lock Room with Code` and a case-sensitive, editable 4–64-character printable ASCII code (no spaces). Locking, editing, and unlocking apply to new admissions; already-admitted guests keep their media credential and reconnect capability. Ending the tour clears admission state.
**Context**: The former generated ten-character tour code derives every GOH4 media-lane key. Editing that code directly would invalidate connected guests. Publishing that code in discovery for open rooms would disclose media keys to passive LAN observers.
**Options**: Re-key all guests on each edit; publish a public media credential for open rooms; or separate admission from the immutable media credential. Chose separate admission to preserve running audio/presentation connections and avoid exposing keys through discovery.
**Contract**: TCP 50003 bootstraps existing encrypted GOH4 lanes without changing their wire format. GOHR v1 challenge is magic/version (5), session UUID (16), locked flag (1), fresh nonce (16), and uncompressed P-256 public key (65). The guest sends its fresh public key (65) and HMAC-SHA256 (32) over the complete challenge plus guest key. ECDH/HKDF-SHA256 derives the bootstrap key, salted with a separate PBKDF2-HMAC-SHA256/600,000 room-code credential (32 zero bytes for open rooms). HKDF info is `GetOverHere/room-admission/v1` plus the transcript. AES-GCM returns only the hidden ten-character media secret, using the transcript as associated data; nonce/ciphertext/tag totals 38 bytes. Room-code PBKDF salt is session UUID bytes plus `GetOverHere/room-code/v1`. Requests and replies are fixed-size, unauthenticated connections are capped at eight, reads/connects have five-second deadlines, and policy revisions cancel in-flight admissions. No codes or crypto material are logged or persisted.
**Discovery**: TXT `admission=1` and `locked=0|1`; equivalent optional JSON fields. iOS monitors TXT updates. Android API 34+ monitors service information; older versions re-resolve serially. Android lock changes withdraw and republish the discovery registration, not the media listeners. Active sessions remain authoritative during that discovery gap. Missing version retains legacy code-based joining; unknown versions fail closed. Both devices need the updated app for the new room behavior.
**Security limits**: Open rooms do not authenticate the guide's identity. A short user-selected code is an access convenience, not strong identity verification; choose a longer code when needed. An active rogue guide knows its own ephemeral private key and can solicit a guest's locked-room proof, compute their ECDH secret, and test candidate codes offline against that proof. PBKDF2 increases guessing cost but does not prevent this attack; this is distinct from a passive observer who lacks the ECDH secret. The four-character minimum is a usability policy, not a strong-security guarantee. Preventing this attack requires a separately reviewed password-authenticated protocol or independently verified guide identity; neither is implemented here. Previously admitted guests are not revoked by locking and can share their credential, as with the existing group-key design. Individual revocation and certificate-based identity are out of scope.
**API references**: [CryptoKit shared-secret key derivation](https://developer.apple.com/documentation/cryptokit/sharedsecret), [Java KeyAgreement](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/javax/crypto/KeyAgreement.html), [Android NSD service updates](https://developer.android.com/reference/android/net/nsd/NsdManager.ServiceInfoCallback).
**Verification**: Core tests cover open/locked admission, wrong codes, replay, identity mismatch, malformed codes, and altered replies. `scripts/verify_room_admission.py` performs real ephemeral-key exchanges in both Swift/Kotlin directions through the CLIs and runs in the CI parity gate. App tests cover actual loopback admission transitions and unchanged media-lane configuration; UI tests exercise the guide toggle and editor. Exact run evidence is recorded in ExperimentLog.md.

## ADR-053: Normalize native decoder initialization and PCM at the Android boundary

**Date**: 2026-09-04
**Status**: Implemented; emulator and physical Pixel codec regressions pass.
**Context**: Live iPhone→Pixel admission succeeded, but Android passed Apple's opaque Opus magic cookie directly as `csd-0`. Native decoding failed, and `MediaCodec.stop()` during cleanup threw on the receive thread and crashed the process. After fixing initialization, the physical decoder returned 48 kHz PCM despite the requested 16 kHz rate, violating the playback contract.
**Options**: Change the wire protocol to carry Android-specific initialization; add a bundled codec library; or normalize native initialization/output locally for the existing negotiated voice profiles.
**Decision**: Normalize at the Android decoder boundary without a wire change or dependency. For the supported 16 kHz mono profiles, construct documented OpusHead/codec-delay/seek-preroll buffers or AAC-LC AudioSpecificConfig. Live Opus admission uses zero file-start pre-skip. Read actual output format, require mono PCM16, and convert 48→16 kHz with a stateful anti-aliased FIR decimator; 16 kHz passes through, other formats fail explicitly. Release codecs directly rather than stopping an error-state codec. Playout close is idempotent and contains/logs decoder cleanup failures, notifying the existing failure path at most once.
**Rationale**: Encoder cookies are platform-specific initialization, not a portable format merely because they fit the same byte-array field. The negotiated profile already contains the required decoder parameters. Playback must honor the decoder's actual output format rather than its requested one.
**Consequences**: Existing GOH4 payloads and Apple production code remain unchanged. New profiles require explicit decoder initialization and PCM support. Fixed regression assets contain generated tones encoded by the production Apple codec, not microphone recordings. Regeneration is not assumed byte-identical across native codec runs. Direct codec tests check duration, amplitude, and frequency; encrypted transport tests require nonzero PCM so concealment silence cannot count as success. Sustained two-phone acoustic/RF acceptance remains separate.
**References**: [Android MediaCodec initialization and lifecycle](https://developer.android.com/reference/android/media/MediaCodec), [Opus identification header](https://www.rfc-editor.org/rfc/rfc7845.html#section-5.1), [Apple magicCookie](https://developer.apple.com/documentation/avfaudio/avaudioformat/magiccookie).

## ADR-054: Bluetooth room discovery is independent of LAN admission and audio

**Date**: 2026-09-04
**Status**: Software implementation and virtual-device checks complete; physical Wi-Fi-off acceptance pending.
**Context**: With Wi-Fi disabled, phones could not discover rooms. Both production coordinators constructed `LocalControlPlane` (Bonjour/NSD only). The unused `BLEControlPlane` files did not run, and both apps lacked Bluetooth permission declarations. Merely enabling the old JSON command channel would not provide safe admission, authenticated control, or audio.
**Options**: Revive the legacy bidirectional GATT command channel; implement the entire BLE tour transport at once; or add an independently testable read-only discovery slice. Chose the discovery slice approved by the user, preserving LAN behavior and making its limited capability explicit.
**Decision**: Keep `ControlPlane` and the existing coordinator wiring. `LocalControlPlane` owns a `BluetoothRoomDiscoveryInterface` implementation alongside Bonjour/NSD. Advertise only when hosting a room. A separate read-only GATT service exposes public room metadata; there are no writable characteristics, credential fields, addresses, participant positions, or tour-control messages. The old BLE command transport remains unused.
**Wire contract**: Service UUID `A1B2C3D4-0005-0000-0000-000000000000`; read characteristic `A1B2C3D4-0006-0000-0000-000000000000`. GOR1 record: ASCII magic `GOR1` (4 bytes), flags (1; bit 0 Android, bit 1 locked, other bits rejected), room UUID (16 RFC/network-order bytes), guide UUID (16), big-endian UTF-8 name length (2), name (1–400 bytes). Total 40–439 bytes. This advertises the current standard-voice/room-admission-v1 profile only. Invalid magic, flags, lengths, trailing data, and malformed UTF-8 fail explicitly. Swift and Kotlin tests share an exact hex fixture and Unicode roundtrips. GOH4 media/admission formats are unchanged.
**Radio lifecycle**: Scan for this service only. At most four simultaneous nearby-guide GATT links; this is not a four-guest tour limit. Clients reread metadata every three seconds, disconnect stalled reads/connections after nine seconds at the next tick, and expire unrefreshed room observations after twelve seconds at the next tick. Long reads use per-central snapshots with offset validation, bounded to sixteen snapshots and ten-second retention. The discovery index caps room identities at sixty-four. Stop cancels scanning, advertising, timers, links, and observations; Bluetooth power/permission recovery restarts discovery. Foreground discovery is the acceptance scope; background/range/group capacity are not qualified by this slice.
**Merging and UI**: Normalize UUID keys within each platform and merge observations by room. A resolved LAN address wins; Bluetooth never supplies or replaces an IP address. Removing one source retains the other. Unresolved LAN-only observations are not mislabelled as Bluetooth rooms. A Bluetooth-only room is visible as `Nearby via Bluetooth · Audio unavailable`, with joining disabled. Loss of the LAN observation does not itself restart or clear an authenticated session. Existing lane failures/reconnect policy remains authoritative.
**Permissions**: Restore iOS `NSBluetoothAlwaysUsageDescription` and Android scan/connect/advertise runtime permissions, with legacy declarations for API 26–30. Android scan declares `neverForLocation`; BLE results do not derive location. Bluetooth denial/off does not disable LAN, and the empty-room UI explains the needed radio/access. No background Bluetooth capability or location permission expansion is added beyond the existing foreground location permission needed for Android's older BLE API.
**Verification limits**: Metadata, merge policy, production observation forwarding, session preservation, and discovery-only UI are software-testable. Actual iPhone↔Android advertising, long reads, lock changes, end/expiry, and Wi-Fi-off visibility require physical proof in both guide directions before this gate is complete. A device being visible is not proof of Bluetooth admission, presentation delivery, or live voice; those remain separate work.
**References**: [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth), [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions), [Android GATT server read callbacks](https://developer.android.com/reference/android/bluetooth/BluetoothGattServerCallback).

## ADR-055: Explicit foreground Bluetooth intent and bounded admission completion

**Date**: 2026-09-05
**Status**: Implemented; physical Bluetooth acceptance remains pending. This updates ADR-054's lifecycle, not its transport capability.
**Context**: The discovery preview requested Bluetooth permission at launch and scanned throughout LAN tours. Both roles opened GATT servers. Admission completed a reply while holding the guide's policy lock with potentially blocking socket I/O. Reverse native-codec interoperability and leading-zero ECDH behavior lacked deterministic tests.
**Options**: Automatically start Bluetooth when LAN discovery is empty; expose an explicit preview toggle; or remove the preview until BLE admission exists. Choose explicit intent so first-launch LAN use needs no Bluetooth prompt. For admission completion, moving blocking writes outside the lock would weaken the policy-update boundary; use one nonblocking send under the lock instead.
**Decision**: Add a non-persisted `Bluetooth room discovery` toggle. While opted in and foreground, an idle browser scans and a broadcasting guide advertises. A LAN guest, backgrounded app, or disabled toggle stops the preview and its links. Browsers do not open GATT servers; guides do not scan. iOS creates only the needed manager with power alerts disabled, and alternates three-second scan/rest bursts without duplicates. Android uses balanced scanning and a thirty-second failure retry interval. Keep the existing metadata read/index bounds; these are not a measured group-capacity claim. No new background entitlement or Bluetooth payload lane is added.
**Admission**: Prepare a nonblocking descriptor/channel before acquiring the policy lock. After checking the listener and policy revision, attempt the complete fixed-size AEAD reply once. Short/blocked/error writes reject admission and close the socket; incomplete replies cannot disclose a media credential. iOS uses `O_NONBLOCK`; Android uses a nonblocking `SocketChannel`. The full-socket regression exposed that `MSG_DONTWAIT` alone did not keep the simulator socket-pair fill nonblocking. No socket-writability wait occurs under the policy lock. Accepted-socket timeout setup now resides inside Android's permit-release `try/finally`.
**Codec/ECDH evidence**: Real production Android Opus and AAC packets decode through the unchanged iOS decoder with duration, frequency and level assertions. Retain generated-tone fixtures; the fresh export harness uses an explicit test-process environment in a generated `.xctestrun` file. No reverse decoder defect was reproduced. Swift and Kotlin derive the same key for private scalars 1 and 379, whose shared secret begins with zero; Kotlin explicitly rejects provider output not exactly 32 bytes. Android instrumentation checks its installed provider as well. The main verifier now includes the real cross-language room-admission exchanges, not only core parity.
**Limits**: The toggle is a discovery preview, not a route selector or a Wi-Fi-off joining/audio feature. Locked-phone discovery and continued locked-phone BLE delivery remain separate unimplemented acceptance cases. Neither scan duty cycle nor link/snapshot limits establish battery life or group capacity. The active-guide offline dictionary attack remains a documented protocol limitation in ADR-052; this change does not implement a PAKE or verified guide identity. Keep the stable LAN tag at `59b0402`.
**References**: [Core Bluetooth power alert option](https://developer.apple.com/documentation/corebluetooth/cbcentralmanageroptionshowpoweralertkey), [Android scan settings](https://developer.android.com/reference/android/bluetooth/le/ScanSettings), [SocketChannel nonblocking writes](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/nio/channels/SocketChannel.html), [XCTest authorization reset](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/resetauthorizationstatus(for:)).

## ADR-056: Direct nearby byte connections reuse admitted session lanes

**Date**: 2026-09-06
**Status**: Experimental direct-session implementation. Supersedes ADR-054/055's discovery-only capability, not their historical evidence. Signed relay and mixed-platform Aware remain incomplete.
**Context**: Guests could see Bluetooth rooms but could not join. The previous Aware lane wrappers did not own production discovery/listening. The user requested one integrated implementation and automated testing before another manual feedback round.
**Options**: Rewrite admission and every media transport for GATT messages; implement a new mesh wire protocol first; or adapt native reliable byte connections to the existing independent authenticated lanes. Choose the adapter for direct sessions, retaining native radio endpoint ownership outside the platform-neutral cores. This does not substitute for the separate signed-relay design.
**Decision**: `LocalControlPlane` owns native Bluetooth and Aware discovery and resolves a room UUID to a native byte connector. Remote advertisements never contain invented loopback addresses. Guest-only listeners on `127.0.0.1:50000–50003` adapt existing transports into native connections. Guide adapters allow only those fixed local lanes and validate the current room UUID; they are not arbitrary proxies. LAN observations take precedence, then Aware, then Bluetooth. Existing media credential, session identity, stream identity, sealing, opening, replay checks and receiver expiry remain unchanged. A reconnect re-resolves native endpoints without another code prompt; discovery resumes during reconnect if explicitly enabled.
**Wire**: GOD1 selector is exactly 21 bytes: ASCII `GOD1`, lane byte (0 metadata, 1 realtime, 2 control, 3 asset, 4 admission), and 16 network-order UUID bytes. Metadata requires the zero UUID; session lanes reject it. Metadata replies have a two-byte big-endian length followed by GOR1. Accepted session lanes reply with one zero byte, then carry the unchanged application stream. Invalid selectors or a different/ended room close the stream. Swift/Kotlin fixtures include 500 UUID/lane roundtrips and deterministic queue bytes. The existing GATT record/service remain unchanged; read characteristic `A1B2C3D4-0007-0000-0000-000000000000` carries the two-byte big-endian L2CAP PSM (zero means unavailable).
**Bluetooth**: Core Bluetooth publishes unencrypted L2CAP streams; Android uses public LE credit-based sockets (API 29+). Application admission and payload AEAD remain mandatory independently of link encryption. Android central opens are serialized after a physical concurrent-open failure; a joined guide link requests high connection priority, reverting to balanced when left. Discovery scanning stops once joined and restarts for endpoint recovery. Active iOS guide/guest Bluetooth ownership is retained in background and `bluetooth-central`/`bluetooth-peripheral` modes are declared. This is not locked-phone proof.
**Bounds**: Each adapter admits at most 32 connections, including pending handshakes; selector setup has a 10-second deadline. Realtime adapters preserve complete immutable sealed frames, with at most eight queued frames and a 16 KiB frame ceiling. Oldest audio can be dropped; handshake/control cannot be evicted. Audio queued over 150 ms is discarded, and a blocked realtime write closes the route after one second. Control/assets stream 16 KiB chunks with backpressure on separate connections. Independent connections do not guarantee priority at the shared Bluetooth controller. No mesh, group-capacity, thermal or battery guarantee follows from these bounds.
**Aware**: `_goh-tour._tcp` is owned by real app listeners/browsers. Android's server port is 50004, avoiding admission port 50003. API 34+ ownership checks runtime support and resource capacity, never evicts an established participant for a new one, and uses network-bound sockets. Android NDP security uses the current displayed device PIN with explicitly selected SK-128. Devices without native pairing use this PIN-secured NDP directly. Port/protocol advertisement requires matching security; the responder registers before notifying the initiator to request its path. Apple uses WiFiAware/Network system-paired endpoints at iOS 26.4+, without raising the iOS 17 floor. These distinct link-security setups do **not** implement Android↔Apple Aware interoperability. The UI directs mixed groups to LAN/Bluetooth; no hidden/private platform API is used.
**Security limits**: GOR1/GOD1 are public routing metadata, not authentication. Open-room admission and the active malicious-guide short-code attack remain as documented in ADR-052. This does not add a PAKE, independently pinned guide signing key, signed forwarding, or protection against every admitted guest forging a shared-key packet. Device PIN security is independent of optional room locking. No production error log includes raw exception messages or credentials.
**Evidence**: Physical Pixel 11 Pro and Pixel 7 (API 37) completed locked admission, pointer updates, byte-exact assets, and 100 non-silent native decoded frames over BLE and Android Aware in both guide directions. Earlier failed attempts remain in ExperimentLog. Virtual tests cover adapter sockets, lock/edit/unlock, wrong-room rejection, source fallback, lifecycle cleanup, queue bounds and cross-language fixtures. iPhone developer connectivity failed; iPhone radio interoperability, Wi-Fi-toggle recovery, locked operation, acoustic quality, 5/10/50-device scale and endurance are not inferred from these tests. Preserve `stable-local-network` at `59b0402`.
**References**: [Android LE credit-based sockets](https://developer.android.com/reference/android/bluetooth/BluetoothDevice#createInsecureL2capChannel(int)), [Android Aware port/security contract](https://developer.android.com/reference/android/net/wifi/aware/WifiAwareNetworkSpecifier.Builder#setPort(int)), [Apple Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware).

**Wi-Fi-off follow-up**: Native socket buffering exceeded the application queue and delivered expired speech. Add a four-frame per-direction acknowledgement window on the native realtime connection only: a four-byte zero length acknowledges the oldest in-flight complete frame; nonzero records retain their existing length and bytes. ACKs are serialized with data writes, stripped before GOH2, and do not authenticate application content. An unexpected ACK or a one-second missing-ACK deadline closes the route. A fifth frame cannot enter the native socket until capacity returns. Both cores retain the same payload wire format; both platform adapters implement the hop framing. With this change, physical Android fixtures passed in both directions with Wi-Fi disabled before joining. This proves the tested disabled-radio setup, not seamless radio toggling during an active tour.

**September 6 iOS failure follow-up**: Signing and installation subsequently succeeded, but the user reported native Wi-Fi Aware error `-11992`. Publish/Subscribe entitlements are present in the signed artifact. The numeric error alone does not establish its cause. Preserve operation and code in the UI, provide explicit retry guidance, and state the current mixed-platform pairing limitation next to the pairing controls. Simulator tests validate these messages, not native RF recovery. Physical testing is paused at the user's request; iPhone Aware and mixed-platform BLE remain unqualified.

**Owner recovery follow-up**: Fatal native discovery termination invalidates that owner's routes and permits explicit restart. Do not retain a dead owner's listener/probes or advertise its cached endpoints as joinable. Local cancellation belongs to its old operation and cannot stop a replacement. Keep per-peer errors separate so one guest does not disconnect the group. The iOS operation/capability boundaries are injectable for lifecycle regression tests; production defaults still invoke native Network/WiFiAware APIs. Android applies teardown only to fatal attach/startup/configuration/termination callbacks.

**September 7 admission completion follow-up**: Physical BLE reproduced a dropped final admission reply when local TCP EOF immediately closed the native guide stream. Guide-side admission now drains until peer closure, with a five-second limit after local EOF; other lanes retain their existing close policy. No new wire bytes, authentication downgrade, or unconditional sleep before delivery are introduced. Both adapters preserve this behavior and test bounded abandoned-peer cleanup. This is an adapter completion fix, not signed admission or mixed-Aware qualification.

**September 7 Android Aware port follow-up**: The physical throughput pilot reproduced `BindException` before publishing. A scoped socket inspection showed an unrelated established outgoing connection already using local port 50004. The active Android Aware owner now binds port zero and advertises the assigned listener port through `WifiAwareNetworkSpecifier`; its guest already consumes `WifiAwareNetworkInfo.port`. GOD1 and the three application lane contracts are unchanged. The socket is closed if binding fails. An emulator regression occupies the old fixed port, fails before this change with `EADDRINUSE`, and passes with dynamic allocation. Do not terminate unrelated connections or claim this explains every earlier discovery failure. The unreferenced older Aware transport is not changed by this fix.

## ADR-057: Canonical signed-guide frame contract
**Date**: 2026-09-07
**Status**: Core prerequisite implemented; app bootstrap and relay integration pending. Does not complete ADR-038.
**Decision**: GOS1 is four ASCII magic/version bytes, a four-byte big-endian sealed-envelope length, the unchanged GOH2 v4 sealed bytes, and a 64-byte unsigned big-endian P-256 ECDSA `r || s` signature. Sign SHA-256 over the domain `GetOverHere/signed-guide/v1` plus a NUL byte followed by the complete GOS1 header and sealed bytes. Bound the inner sealed envelope to 65,536 bytes. Sign once and retain the immutable result for forwarding. Verification requires a caller-pinned 65-byte X9.63 key and expected guide/session IDs; do not include a trusted key in the packet. Verify before inner decoding/AEAD opening.
**Canonical form**: Require `0 < r,s < n` and low-S (`s <= n-s`) using the standard P-256 order. Normalize at signing and reject noncanonical signatures at verification. Otherwise a relay can replace S with n−S and change a valid packet's bytes without knowing the signing key. Android uses its public SHA256withECDSA provider and bounded DER/raw conversion; Swift uses CryptoKit. No custom elliptic-curve or ECDSA algorithm is implemented.
**Options**: DER on the wire, provider-specific fixed-width signing algorithms, or native providers with an explicit canonical wire conversion. Choose the latter for fixed sizes and compatibility with the existing Android API floor. Another shared MAC key would allow every guest to forge and remains rejected by ADR-038.
**Limits**: This core API does not authenticate how a caller obtained its pin, provide replay/expiry checks, or replace existing AEAD/sequence policy. Admission key delivery, lifecycle pinning, guide lane integration and bounded relaying must precede enabling relay traffic. Current production direct-session behavior and the stable LAN tag remain unchanged.
**References**: [CryptoKit P-256 signatures](https://developer.apple.com/documentation/cryptokit/p256/signing/ecdsasignature), [Java signature algorithm formats](https://docs.oracle.com/en/java/javase/25/docs/specs/security/standard-names.html).

## ADR-058: Research informs router-free experiments, not automatic product pivots

**Date**: 2026-09-07 local handoff; supplied research reports self-date 2026-09-08.
**Status**: Recorded direction and validation plan; documentation-only. Does not qualify a route, group size, or new security protocol.
**Context**: After the two-Android Aware benchmark at `7dca55f`, the user asked whether broadcasting enables roughly 30 listeners, commissioned external research, then requested the complete reports and current/remaining work in the handoff. [Claude report](Research-Claude-2026-09-08.md) and [ChatGPT report](Research-ChatGPT-2026-09-08.md) are preserved with their references. They disagree on iOS background behavior and product direction; some claims overstate the supplied measurements.
**Options**: Adopt the reports verbatim; pivot to a mandatory portable AP; or preserve the router-free objective/LAN baseline and test concrete public-API hypotheses while completing existing security/hybrid work.
**Decision**: Preserve router-free as objective and LAN as fallback. Use the adjudicated A1–A4 plan in [NextSession.md](NextSession.md): resource/small-packet measurement; capability-gated public pairing probe; admission-bound guide pinning and immutable signed production frames; direct audio/lock qualification followed by measured bounded relay/hybrid completion. Archive older checkpoints in [NextSession-History.md](NextSession-History.md), not as current status.
**Rationale**: Apple DTS permits Aware connections during legitimate background execution; screen lock is not equivalent to suspension. Android documents framework-offloaded pairing in version 37.2, but our recorded major API 37 does not prove runtime/hardware support. Existing `NearbyTCPConnection` already enables TCP_NODELAY, so the latency distribution alone does not diagnose Nagle. Current native adapter connections are bounded separately from NDPs and guests. Report bandwidth arithmetic omits some application framing; two-phone goodput establishes neither 30-phone capacity nor acoustic timing.
**Consequences**: Do not trust a guide key merely because discovery advertises it, omit signatures on intervening frames, duplicate signing per destination, or label first-contact TOFU as verified human identity. No mandatory-router pivot, multicast rewrite, lowered platform baseline, PAKE/profile/library adoption or individual revocation is authorized solely by a report. Keep the optional editable room lock and existing security limits explicit. New radio/scale/acoustic claims require physical evidence; safe independent software work continues without repeated requests for unavailable iPhone testing. Keep `stable-local-network` at `59b0402`.
**References checked during synthesis**: [Apple background Aware guidance](https://developer.apple.com/forums/thread/787570); [Android offloaded pairing](https://developer.android.com/reference/android/net/wifi/aware/PublishConfig.Builder#setFrameworkOffloadedPairingEnabled(boolean)); [Apple performance tuning](https://developer.apple.com/videos/play/wwdc2025/228/); [current socket options and connection cap](Android/app/src/main/java/com/aessam/comeoverhere/core/NearbySocketBridge.kt). Other report citations remain source leads unless independently checked.

## ADR-059: Admission-bound guide authority and renderer-reported readiness

**Date**: 2026-09-08.
**Status**: Software implementation and full integrated virtual-device gate passed. Physical qualification remains open; this is not a release or30-listener claim.
**Context**: The user approved implementing the complete router-free plan, permitting first-use system pairing while retaining open rooms and optional guide-edited room locks. They then left home and withdrew physical-device availability. Discovery-only success and connected sockets must not be presented as working audio.
**Decision**: Native production admission moves atomically to GOHR v2. Its 103-byte challenge and 97-byte request bind a 183-byte encrypted reply containing the internal media secret, expected guide UUID, 65-byte signing key and canonical P-256 possession proof over the fresh transcript. Reuse one signer per guide session across admission and every guide-origin audio/control/asset frame, including lane handshakes. Guests pin the admitted session/guide/key and verify GOS1 before AEAD. Reconnect retains the pin; explicit leave/new session permits replacement. Signature failures are terminal, not retryable radio failures. Native owners start unconfigured and fail closed; unsigned compatibility is explicitly selected only by component fixtures.
**Discovery compatibility**: GOR2 carries admission version 2 using the same bounded record layout. GOR1 remains version 1 and its fixture is unchanged. Never relabel old nearby records as v2. New app joins reject old admission versions with an update message; the stable LAN tag is preserved for the old coordinated build pair.
**Readiness**: Audio startup reports errors explicitly. Local capture/playback state is independent of room connection state. A guest reports `audioStatus` (control kind `0x24`) only from its runtime; PLAYING follows renderer acceptance, not a socket welcome. Guides count only connected senders' increasing reports and remove readiness on disconnect. The fixed payload is version 1, one status byte and a big-endian 64-bit revision. This is renderer readiness, not acoustic proof. Retry Audio restarts only the audio lane/renderer; microphone restart retains the room and its control/assets.
**Alternatives rejected**: Treating a discovery key as trusted identity; signing per destination; accepting missing guide authentication; silently falling back to v1; treating connection count as playback count. Optional SHA-256 signing-key fingerprints are comparison aids, not automatic human-identity verification. Existing short-code/TOFU and revocation limitations remain; no PAKE or custom cryptography was added.
**Envelope bound**: Keep the 65,536-byte maximum inner signed envelope. Reduce production asset chunks to 60 KiB to leave room for metadata and authenticated framing; range/hash resume does not require a fixed chunk length. Bridge queue classification understands the bounded GOS1 wrapper but does not itself claim signature verification.
**Evidence**: `/tmp/GetOverHere-capacity-topology-core-parity-final.log` (61 Swift/64 JVM core tests; v1/v2 exchanges, GOR2/readiness fixtures and signature parity); `/tmp/GetOverHere-ios-signed-tour-retry.log` and simulator result `Test-GetOverHere-2026.09.08_08-59-18--0700.xcresult` (129 tests, 150 parameterized runs passed, one physical-only skip); `/tmp/GetOverHere-android-a2-readiness.log` (JVM suite and instrumentation APK build passed). No physical radios or acoustic/endurance/group claim was tested this session.

## ADR-060: Native route ownership, capacity and public pairing profiles

**Date**: 2026-09-08.
**Status**: Implemented; integrated virtual-device gate passed. No new physical-radio evidence.
**Context**: A room name is not a usable route. Returning only `127.0.0.1` loses the distinction between LAN and a native Bluetooth/Aware adapter. Separate bridge limits also missed app-wide ownership, and sockets to one Aware peer must not be counted as distinct physical peers.
**Decision**: Return a typed nearby route containing adapter host, carrier, room and ownership token. Before publishing a route, preflight bounded native metadata against the selected room, expected guide and admission-v2 version. Metadata checks do not replace cryptographic admission. Preserve a healthy cached route; replace failed ownership, reject identity/version mismatch, and permit transport-failure Aware-to-BLE fallback with an explicit reason. Reconnect retains the admitted guide pin; stop/late callbacks cannot free a replacement owner's reservation.
**Software budgets**: Shared nearby bridges/probes account for 90 persistent connections (30 listeners × three lanes) plus eight transient bootstrap connections. Promote only validated persistent selectors. Release exact leases on cancellation, completion and owner teardown. Native audio/control/asset listeners separately reserve unique participants before welcome, reject listener31, permit a same-member replacement and ignore stale disconnects. These bounds do not reserve NDPs, prove 30 radios or override native handshake-rate limits.
**Native capacity**: Query documented maximum/current Aware resources and track pending requests across profiles. Android reuses the selected peer's `Network`/callback for metadata, admission and all application sockets; those sockets do not each reserve another NDP. Record actual network handle/interface and profile. Apple exposes a maximum-connectable-devices observation; it is not an endurance or group-performance result. Unknown capacity is not silently replaced with eight or thirty.
**Pairing**: Compile against public Android37.2 while retaining target36/min26. Android compatibility PIN/SK-128 uses `_goh-andr._tcp`; the system-paired subscriber candidate uses Apple's `_goh-tour._tcp`, full-version/hardware/keypad/discovery-resource checks, framework-offloaded pairing and35s request timeout. The existing iOS26.4 implementation guard stays. Profiles have independent discovery/path ownership and share app budgets; one profile failing cannot stop the other.
**Public contract limit**: Android's documented endpoint port/protocol setters require an application security configuration, while framework-offloaded pairing does not expose its key. System-paired Android publishing therefore reports unavailable in this implementation. No dummy PSK, fixed first-contact Apple port, reflection or private API workaround was added. A reverse-dial transport-role design is a future integration task, not a completed bidirectional profile. See [Android Builder](https://developer.android.com/reference/android/net/wifi/aware/WifiAwareNetworkSpecifier.Builder), [offloaded pairing](https://developer.android.com/reference/android/net/wifi/aware/PublishConfig.Builder#setFrameworkOffloadedPairingEnabled(boolean)) and [Apple additional-connection bootstrap](https://developer.apple.com/forums/thread/818708).
**Alternatives rejected**: Raising each owner's independent constant; calling adapter sockets LAN; reserving one NDP per socket; silently changing guide identity during fallback; evicting healthy guests for overflow; presenting eligible public APIs as measured cross-platform interoperability.
**Relay consequence**: The bounded topology planner remains only a planner. Native relay needs guide-authorized, key-possession-bound leases, dual native roles, per-session replay retention and a fresh guide time/sequence anchor. GOD1 currently has no hop/lease/parent field. Blind duplex proxying would also carry guest requests/readiness, which needs an explicit ADR-038 authority review. Do not enable forwarding by treating a participant UUID or copied lease as proof. No 30-person relay claim follows from socket-capacity tests.

## ADR-061: Bounded guide asset scheduling and current-slide priority

**Date**: 2026-09-08.
**Status**: Mirrored core, native service and final integrated virtual-device gates pass. Physical coexistence remains untested.
**Decision**: Reuse the existing content-addressed cache, range requests and chunk protocol. A guide-owned scheduler permits at most30 registered members and two outstanding requests per member, including reads in flight. Deduplicate member/hash/offset; reservations carry unique completion tokens. Select members round-robin and prefer their current/next slide hashes within each turn. Pace aggregate payload at an explicit512KiB/s default with at most one60KiB chunk of accumulated credit; this is a conservative software policy, not measured BLE/Aware capacity.
**Lifecycle**: Stop, manifest replacement and participant replacement invalidate delayed work. Old completion tokens cannot free a replacement request. Native drains are asynchronous/scheduled, not sleeps on the UI/event worker. Guests receiving a new current slide can yield a background transfer only after ingesting its outstanding chunk; the partial file resumes later. Never issue a duplicate request for a still-outstanding chunk.
**Limits**: This is bounded asset admission/pacing, not a complete radio-aware audio/control/asset arbiter. Distinct sockets still share radio resources, and an in-progress native write is not preempted by presentation priority. Shared realtime-pressure scheduling and physical audio/assets coexistence remain separate work/qualification. No throughput or latency guarantee is inferred from the configured rate.

## ADR-062: One shared-core type identity in hosted iOS tests

**Date**: 2026-09-08.
**Status**: Implemented and verified by symbol inspection and the full simulator suite.
**Context**: Hosted tests and the app each directly linked the automatic static TourSessionCore package product. A thrown RoomAdmissionV2Error had the expected printed name but could not be caught as that type across the app/test boundary. The mismatch also made a terminal wrong-guide recovery test retry six times.
**Decision**: Keep TourSessionCore linked by the app only. Remove the hosted test target's redundant package-product and framework build entries; retain TEST_HOST/BUNDLE_LOADER so tests import the host's symbols. Do not change the package into a dynamic library or compare error strings.
**Proof**: Before the change, both GetOverHere.debug.dylib and GetOverHereTests defined the RoomAdmissionV2Error metadata and Error-conformance symbols. Afterward the test bundle imports those symbols. Focused suites passed 55 tests/64 runs; the full simulator result at 10:56 passed 155 tests/189 runs, with one physical-only skip. See ExperimentLog for paths and commands.
**Consequence**: Test-target linkage is part of a typed-error regression's correctness. A same-named error mismatch must not be hidden by broad catches or weaker terminal-failure assertions.

## ADR-063: Run-owned capture and bounded audio producer admission

**Date**: 2026-09-08.
**Status**: Focused native/software tests, unsigned generic iOS build and final integrated virtual-device gate pass. No acoustic or radio qualification.
**Context**: Bounded socket queues did not bound earlier work. Both native audio producers queued PCM before encoding without a limit, then assigned fresh timestamps after encoding. Android capture cleanup also released global effects/focus even if another session had replaced it; iOS capture taps needed run-owned continuations.
**Decision**: Retain the newest single capture buffer and expose drops. Capture resources, tap continuations and completion/error callbacks belong to the exact run. Stop releases uncollected Android capture exactly once; delayed cleanup cannot release replacement audio/focus. Guide event delivery also checks the logical session generation. Guest socket creation stays inside its error boundary.
**Producer policy**: Admit at most eight queued PCM submissions, each at most32,000 bytes and aligned to PCM16. Stamp at submission, before scheduling. Reject monotonic age≥150ms before and after encoding/sealing. Attribute partial frames and buffered codec output to the oldest contributing submission; cap retained encoder-input timestamps at eight. Overflow, age and discontinuities flush the packetizer/native encoder while preserving stream/monotonic sequence identity. Stop clears pending work and prevents late delivery. Keep independent bounded socket writers; do not serialize all lanes behind one potentially blocked asset write.
**Compatibility and limit**: The public Data/ByteArray audio boundary and wire format are unchanged. Existing500ms wire/jitter lifetime remains, based on the preserved input timestamp. Submission time is not the hardware microphone sample time; these tests cannot establish mouth-to-ear delay. Native audio/control pressure feedback into asset scheduling and physical coexistence still need work/evidence.
**Evidence**: Android's two deterministic stale-capture/factory regressions failed before fixes, then its full158-test JVM suite and APK builds passed. iOS focused75 tests/97 runs passed, including signed delayed-encoder/partial-input/stop tests and old guide callbacks across both replacement roles; generic iOS device compilation passed without signing or devices. Commands and logs are in ExperimentLog.

## ADR-064: Admission reachability fallback and selected-route continuity

**Date**: 2026-09-10.
**Context**: Both native services selected any advertised LAN address without trying an available nearby path after a failed connection. Later LAN announcements could also tear down a successfully admitted nearby route. Reflected or stale discovery is not proof that an address is reachable.
**Decision**: Permit exactly one LAN-to-nearby admission fallback, only for typed connection failures before receiving any challenge bytes. Keep the selected room, expected guide, admission version and user-entered code unchanged. Partial/malformed challenges, identity/version failures and all errors after submitting credentials remain terminal. No broad exception-to-fallback mapping or code-free downgrade.
**Ownership**: A successful admission selects the route. Discovery may update room metadata but cannot replace that route. Preserve nearby selection separately from the current adapter descriptor; invalidate failed descriptors, serialize asynchronous recovery and reject stale attempt/generation callbacks. Audio-only retry must not reopen a stale adapter or silently choose LAN. Session teardown clears both selection and descriptor.
**Alternatives rejected**: Always preferring Bluetooth; retrying any authentication error on another transport; assuming an address announcement verifies reachability; retaining a failed loopback descriptor as a usable route.
**Verification**: Deterministic red/green native lifecycle tests and real local socket tests cover fallback, terminal errors, late admission results, discovery updates and recovery ownership. The physical mixed BLE tests additionally exposed a separate iOS-central multi-channel failure; this routing change does not claim to fix that native failure. Exact commands/results are in ExperimentLog.

## ADR-065: Distinct Android Bluetooth endpoints for independent tour lanes

**Date**: 2026-09-10.
**Context**: Physical iPhone12mini/iOS26.5.2→Pixel11Pro/SDK37 central-to-peripheral opening succeeded once but failed for additional simultaneous channels on the same Android PSM. Sequential invocation produced the same result, ruling out queued-callback timing alone. The test-only distinct-PSM host then accepted three simultaneously held native channels. This is evidence about this device pair, not a universal CoreBluetooth limit or a definition of its private numeric errors.
**Decision**: Android allocates four app-wide public LE CoC listeners, for transient metadata/admission plus realtime, control and assets. Optional GATT characteristic `A1B2C3D4-0009-0000-0000-000000000000` carries exactly12 bytes: ASCII `GOL1`, then four distinct nonzero UInt16 big-endian PSMs in admission/realtime/control/asset order. The legacy0007 characteristic remains admission's PSM and still accepts all existing GOD1 selectors. Swift selects the lane endpoint explicitly and validates returned channel identity. Its iOS host and Android guest retain the previously working single-endpoint path.
**Validation and lifetime**: Reject malformed/unknown/duplicate/zero endpoint maps and mismatch with legacy admission PSM; only absence of the extension permits legacy selection. Opening queues carry the requested PSM per operation. Android owns each allocation before subsequent setup, closes partial sets on failure, and rejects stale accept callbacks. Every stream still enters the existing GOD1 selector, room admission/signature/AEAD checks and shared connection budget. Endpoint metadata grants no authority; no arbitrary remote/local port forwarding is added.
**Alternatives rejected**: Blind retry/sleep after same-PSM failure; a random endpoint pool; premature full stream multiplexing that would put assets/audio behind one userspace FIFO; treating a native-open probe as a passing tour. No Aware, LAN or application-message format change is required.
**API basis**: Android's public `listenUsingInsecureL2capChannel()` allocates dynamic PSMs and leaves their disclosure to the app ([Android reference](https://developer.android.com/reference/android/bluetooth/BluetoothAdapter#listenUsingInsecureL2capChannel())). Existing application authentication/encryption remains necessary. Endpoint availability and group capacity require physical qualification.
**Gate**: Mirrored exact-hex/roundtrip/malformed core fixtures, native lane-selection tests, then both-direction mixed protocol and real production microphone/readiness/playback tests. Exact outcomes are appended in ExperimentLog; the native-only success does not itself satisfy the latter gates.

## ADR-066: Explicit, authenticated debug control of the visible iPhone app

**Date**: 2026-09-10.
**Context**: Physical fixtures can exercise a second coordinator without controlling the
visible scene. The user requested a reusable in-app server and external client to drive
the actual app and inspect its real state across their routed local network.
**Decision**: Local SPM library `AppDebugControl` plus Mac executable `goh-control`.
The iOS adapter holds the scene's existing AppCoordinator weakly, executes an allowlist
on MainActor and reports real service state. Navigation uses the same observable feature
selection as the SwiftUI picker. Replies acknowledge an action; clients must poll for
asynchronous completion. No selectors, evaluation, synthetic rooms or permission bypass.
**Security**: Explicit Debug launch flag, 32-byte random key and ephemeral in-memory
P-256 identity supplied over the authorized device launch environment. TLS 1.3 pins the
server certificate; HMAC-SHA256 verifies each request before decoding/execution. UUID
replay rejection, 32 KiB frames, four connections, 10-second connection deadlines,
2,048 requests and 15-minute activation. Owner-only credential files; no trust-store or
keychain edits. State excludes codes/keys. Never expose the listener to the Internet.
**Lifecycle and release**: Mutations require foreground. The active debug session keeps
the screen awake and restores the previous idle-timer value on Stop/expiry/failure;
manual lock or app switching may suspend it. No background mode was added. All server,
adapter and panel implementations are `#if DEBUG`; Release uses the original Info.plist.
The separate Debug plist registers `goh-debug://panel`, which only opens diagnostics.
**Alternatives rejected**: Unauthenticated HTTP command server; mutation/secret-bearing
deep links; a separate test AppCoordinator; arbitrary UI selector execution; private
device-control APIs; silently keeping the app alive with audio. TLS-PSK-only handshake
failed in the local Network.framework smoke, so the implementation uses pinned
certificates plus application authentication, not downgraded encryption.
**Evidence and limits**: Actual TLS/auth rejection tests, simulator adapter tests, signed
device build and Release exclusion checks pass. One physical Mac→iPhone status succeeds;
later requests time out. Updated keep-awake behavior and complete remote UI/microphone
smoke remain pending device relaunch approval. This is tooling, not mixed-tour completion.

## ADR-067 — Separate Bluetooth metadata and release admission listeners synchronously
**Date**: 2026-09-10
**Context**: Physical Android-guide → iPhone-guest joins failed when metadata and
admission reused an Android PSM. Repeated normal iPhone Create/End also reproduced
port50003 bind errno48; cancellation deferred socket close to an accept worker.
**Decision**: Add the optional fifth metadata endpoint in GOL2 (14 bytes), retaining
GOL1 (12 bytes) decoding and fixtures. Android publishes five distinct native PSMs.
Updated peers select metadata separately from admission. Older GOL1-only readers do
not understand GOL2; update both test apps rather than bypassing admission checks.
iOS closes the admission listener before stop returns, with nonblocking accept and
socket identity checked under the same policy lock. Readiness polling is bounded and
outside the lock; an old worker cannot accept on a new owner's reused descriptor.
Normal iOS Find enables Bluetooth; experimental Aware remains an explicit opt-in.
**Evidence**: Cross-language endpoint fixtures, focused admission/lifecycle tests,
five normal physical Create/End cycles, and both normal mixed UI directions pass.
Both mixed directions also pass after the user forgot the iPhone Wi-Fi network.
**Limits**: Android-guide intermittent audio startup and native encoder recreation
churn remain unresolved. A room-flow pass is not locked or acoustic qualification.

## ADR-068 — Keep transport speed benchmarks separate from audio qualification
**Date**: 2026-09-10
**Decision**: Test-only GBB1 in iOS/Android test targets measures byte-verified,
bounded half-duplex Bluetooth transfers and guest-clock echo RTT through production
native connections/guide adapters. No production wire format or authentication path
is replaced. Two guests may run concurrently, with independent phase advancement;
do not report summed medians as a synchronized broadcast bitrate.
Reuse Android Aware's existing bulk and signed small-packet benchmarks. Preserve raw
results, role orientation, failed test selection, build hashes, and exact commands.
Require positive actual test counts, verified payloads, both endpoint completion and
monotonic receive timing before accepting a row. Simulator loopback is a protocol
gate only. The three-phone report lives in `benchmarks/2026-09-10/README.md`.
**Consequence**: Role-dependent Bluetooth throughput and Aware latency tails stay
visible. These tests cannot certify microphone-to-speaker latency or thirty guests.

## ADR-069 — Two-hub wired gateway, without listener relays
**Date**: 2026-09-11
**Status**: September15 review repairs implemented; all nine software gates pass.
Native emulator, cross-runtime TLS and simulator evidence are indexed in
`benchmarks/2026-09-15-security-review/README.md`. Physical gateway qualification NOT RUN.
**Decision**: Either phone owns the tour; the other is a dedicated USB-connected
companion. iOS listeners use native Network.framework Apple peer-to-peer; Android
listeners use Wi-Fi Aware. The user explicitly chose two hubs only and a measured
audience cap, even if below30. Listener relays/election are excluded. The companion
may stay awake; locked listener playback remains required. This supersedes the
platform-island-bridge exclusion in ADR-029 only for this explicit wired mode.
**Architecture**: Each leaf's admission/realtime/control/asset connection is
proxied to the original guide's existing services. No second producer, signer,
room, shared media key on the companion, or participant substitution. Radio-hop
ACKs do not enter the USB application stream. Fixed lane selection is not an
arbitrary-address TCP proxy. Admission budgets retain capacity for local guests.
**Pairing**: Separate hub certificates; mutually pinned TLS1.3; two-way public
DER-certificate SHA256 fingerprint QR exchange, fresh pairing ID and final guide
confirmation. Incomplete enrollment expires after120s; a confirmed association
does not expire merely because that enrollment deadline passes. Certificate
replacement requires fresh enrollment. GHP1/GHL1/GHD1 are versioned companion-only
records; existing GOHRv2/GOS1/GOH2 application bytes remain unchanged inside TLS.
Each GHD1 descriptor has a one-byte zero acknowledgement on hub-control only;
the guide waits for that reply under the three-second liveness deadline. Successful
buffered writes alone are not companion liveness evidence.
Unsigned63-bit bounds keep positive Swift/Kotlin counters aligned. TLS capability
is gated separately from existing app OS floors. No accept-all certificate phase.
**Route and freshness boundaries**: USB addresses/interface names are observed,
not hardcoded. Each Aware socket uses its own Network; never bind the whole app.
Apple includePeerToPeer permits but does not prove P2P; strict physical runs need
no AP association and route evidence. The opaque gateway bounds local audio dwell
(initial50ms), not encrypted source expiry. Qualified audience caps are distinct
from socket limits and native reported resources. Original guide platform is
separate from the local provider platform.
**Verification**: See GatewayImplementationPlan.md for contracts, ordered gates,
quality targets and failure conditions. USB ICMP evidence alone does not pass
application throughput, radio coexistence, playback, lock or endurance gates.
**Confirmed-association recovery**: The initial QR endpoint is bootstrap, not the
identity of the guide. Replugging USB may replace an address. Preserve pairing ID,
room/guide IDs and both certificate/guide-key pins independently of the current
endpoint. Advertise the single service `_goh-hub._tcp`, port50104, with instance
`goh-` plus the lowercase canonical pairing UUID. Discovery contains no secret or
room authority. The companion accepts only matching, on-link candidates from its
selected wired discovery owner; mutual TLS and the fixed-lane request still prove
the association. A confirmed reconnect creates a new route generation, while old
lanes close. Ending/removing the association cancels discovery and all retries.
The guide's own native audience branch remains running during cable loss.
**Discovery API choice**: Apple uses native Bonjour with a required wired interface.
Android's NSD Network selector is not sufficient for a tethering downstream whose
`Network` is null; null requests are not a wired-only interface binding. Use a
reviewed interface-scoped mDNS implementation with an explicit local address and
network interface, not default-route NSD or a custom DNS parser. Reject missing
interfaces and ambiguous/off-link candidates. Source binding is diagnostic evidence,
not by itself proof of physical USB routing. Android pins `org.jmdns:jmdns:3.6.3`
(Apache-2.0; transitive `slf4j-api:2.0.7`). Its public fatal-recovery delegate and
application lifecycle/configuration/close errors feed Android logging; no claim
is made that every internal SLF4J message is delivered. Configuration supplies a
non-personal cached hostname to avoid reverse-DNS lookup. See
[release v3.6.3](https://github.com/jmdns/jmdns/releases/tag/v3.6.3) and
[published POM](https://repo.maven.apache.org/maven2/org/jmdns/jmdns/3.6.3/jmdns-3.6.3.pom).
Sources: [Apple requiredInterface](https://developer.apple.com/documentation/network/nwparameters/requiredinterface),
[Android NsdServiceInfo Network contract](https://developer.android.com/reference/android/net/nsd/NsdServiceInfo#getNetwork()),
[JmDNS public interface-scoped API](https://jmdns.sourceforge.net/apidocs/javax/jmdns/JmDNS.html).
**Local branch ownership**: Guide pairing enables the original guide's own native
publisher, not the companion proxy publisher. Removing a companion preserves the
original audience branch until the tour ends, then restores the prior preference.
Companion discovery suppression restores only the preferences it acquired.
Diagnostics follow the current role's actual publisher. Both normal UI entry
points and role lifecycles are covered; native radio availability remains physical.
**Software evidence**: The nine-stage main gate passes; Android198 app tests and
native9, iOS196 app test definitions/242 runs (four device-only fixtures skipped),
gateway262 cross-language cases, actual Apple/Android TLS in both server roles,
visible setup/debug UI and Release exclusion all pass. Full results and retained
failed attempts are in `benchmarks/2026-09-11-gateway-software/README.md`.

## ADR-070 — Bounded gateway recovery and enrollment clocks
**Date**: 2026-09-15
**Status**: Implemented; software gates pass. Physical acceptance deferred.
**Context**: Review F1–F12 exposed recovery/resource failures despite the earlier
happy-path gates. Offline peers need not have equal wall clocks; codec capture
expiry is not equivalent to terminal codec failure.
**Decision**: Keep the two-hub architecture and existing wire formats. Companion
offer validation permits at most30s skew; the issuer still validates its original
response expiry strictly. Local enrollment timers use bounded monotonic durations.
Expired hub certificates may renew only during an explicitly started new two-way
QR enrollment, never underneath an existing confirmed pin.
**Recovery**: Replace Android encoders after exceptions or2s without output,
allowing at most3 replacements per codec per tour, then report an actionable
failure. New instances use new stream IDs. Retain warm encoders across ordinary
capture expiry. Selected Apple connectors own endpoints independently of scan
tasks; multiple candidates repair advertisement loss. One native Android owner
controls retries; both platforms expose exhaustion and deliberate retry.
**Resource contract**: Shared lane capacity precedes acceptance. Ownership covers
allocation, connect, ACK and forwarding. Android TLS/header/open work has an
absolute5s deadline; gateway reliable writes use a reported5s deadline on both
platforms. Ordinary baseline nearby copying is unchanged by that gateway policy.
**Alternatives rejected**: Removing all codec recovery; restarting on each expired
frame; globally weakening issuer expiry; silently rotating confirmed pins;
accepting then discovering capacity failure; two competing reconnect loops.
**Consequences**: Hardware qualification can still expose radio/codec behavior
outside these software fixtures. Physical group cap, locks, acoustic timing and
endurance remain unqualified. Evidence and exact commands:
`benchmarks/2026-09-15-security-review/README.md`.

## ADR-071 — Preserve playout sequence across Android encoder replacement

**Date:** 2026-09-23. **Tracking:** GitHub #1.
**Context:** Guests retain their playout clock when a replacement encoder emits
the same codec configuration. Resetting sequence to zero makes valid recovered
frames look like duplicates.
**Decision:** Keep a per-codec sequence in the broadcast processor for its lifetime,
independent of replaceable encoder state. Retain fresh cryptographic stream IDs.
**Alternative rejected:** Resetting guest clocks on every crypto stream change
would require changing both receive paths and handling delayed old-stream frames.
**Consequences:** No wire change. Component regression traverses signed encrypted
sender output into the existing guest clock; radio/native/acoustic evidence remains
required. Sequence exhaustion is explicitly rejected rather than wrapping.

## ADR-072 — Deliver PDFs as guide-rendered page slides

**Date:** 2026-10-04. **Tracking:** GitHub #2, `WirelessMegaphonePlan.md`.
**Context:** The cross-platform no-router route is Bluetooth, measured at
0.25–0.53 Mbps payload per guest (`benchmarks/2026-09-10/README.md`). A whole
multi-megabyte PDF would delay the first visible page by minutes per guest.
Slides already have current-slide-first delivery, SHA-256 verification, resume
and late-join restore.
**Decision:** The guide renders each PDF page to a bounded JPEG and imports it
through the existing slide pipeline. The PDF page number is the slide index.
No new asset kind and no GOH2 wire change.
**Alternatives rejected:** A new PDF asset kind (slow first page, a wire change on
both platforms); per-page PDF extraction (Android has no public page-copy API).
**Consequences:** Guests see raster pages at a fixed resolution, with no vector zoom
or text selection. Size caps are enforced at import. Physical audio and transfer
coexistence on Bluetooth remains unqualified.
