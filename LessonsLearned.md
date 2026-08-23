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

## 15. Wi-Fi Aware source support and signing support are separate gates
**What happened**: The iOS 27 SDK compiled the Wi-Fi Aware implementation, but the existing team provisioning profile did not contain `com.apple.developer.wifi-aware`. Xcode could not refresh it because the selected Xcode installation had no developer account configured.
**Resolution**: Keep unsigned device compilation and wire tests as source gates. Treat a refreshed entitlement-bearing profile as a required physical-device gate.
**Decision**: Check capability provisioning before scheduling any Wi-Fi Aware field test. A successful compile does not prove an installable build.

## 16. Runtime radio limits must be measured per device
**What happened**: The connected Pixel 11 Pro reports 8 maximum NAN data paths, 8 publish sessions, and 8 subscribe sessions. These are hardware/firmware values, not universal Android limits.
**Decision**: Record `Characteristics` and `AwareResources` for every test device. Never turn one phone's NDP count into a supported group-size claim.

## 17. One-way megaphone feedback is not duplicate network delivery
**What happened**: Cross-platform speech was crisp but echoed when the guide and listener phones were near each other. Inspection confirmed one-way capture and one transport write per listener. The listener loudspeaker was acoustically feeding delayed audio into the guide microphone.
**Resolution**: Make receiver/headset playback the listener default, retain a warned speaker override, and enable supported voice-communication preprocessing on guide capture.
**Decision**: Treat output routing as the first anti-feedback control. Do not assume same-device AEC can cancel playback from neighboring guest phones.

## 18. Discovery peers are not listeners
**What happened**: The guide streamed audio to a guest while the UI showed zero listeners. `listenerCount` read Bonjour/NSD control-plane peers, which describe discovered publishers, not guests attached to the guide's audio server.
**Resolution**: Add a GOH2 hello to the actual session connection and maintain a participant registry keyed by stable participant ID. Disconnect by connection ID, and replace an older connection when the same participant reconnects.
**Decision**: Product membership and counts must come from the product session, never from discovery or socket totals.

## 19. Cross-platform protocol changes need executable byte equality
**What happened**: Existing Swift Codable and hand-built Kotlin JSON had already drifted in earlier work. Semantic roundtrip tests on each platform would not detect different encodings.
**Resolution**: Create shared Swift and Kotlin session cores, deterministic binary fixtures, CLIs, and `scripts/verify_tour_session.sh`. The gate compares exact bytes in both directions and exercises 1/8/20/50 participant churn plus loss, duplicate, and reorder accounting.
**Decision**: A wire-format change is incomplete until Swift and Kotlin emit identical bytes and decode each other's output.

## 20. Discovery diagnostics do not belong in the tour flow
**What happened**: Both apps exposed peer counters that looked like listener status, and both creation screens exposed an audio-quality choice that was not actionable for the tour guide.
**Resolution**: Remove discovery counters and quality selection from the product flow. Keep radio diagnostics in the explicit Wi-Fi Aware lab and use the standard audio profile by default.
**Decision**: Product UI reports session state only. Transport diagnostics stay behind diagnostic surfaces.

## 21. Reliable does not mean one FIFO
**What happened**: Slides and offline maps require reliable transfer, but placing them beside audio or guide commands would let a large asset delay time-sensitive data. Enqueueing every chunk at once would also create a large per-guest memory backlog.
**Resolution**: Use independent authenticated sockets for control and assets. The guest requests exactly one 64 KiB chunk at its persisted offset, verifies and writes it, then requests the next chunk. Final readiness is sent only after SHA-256 verification.
**Decision**: Separate traffic by latency class. Reliable asset transfer must be bounded, resumable, content-addressed, and backpressured by the receiver.

## 22. Privacy constraints belong in the wire schema
**What happened**: The map needs a local user position for useful guidance, but the product permits sharing only the guide-selected target pin.
**Resolution**: Keep device position, heading, accuracy, history, and movement inside platform guidance services. The only coordinate-bearing network message is the versioned target snapshot. Add exact cross-platform fixtures and source checks around that contract.
**Decision**: Do not rely on UI copy or convention to protect location data. If a value must not leave the device, omit it from every transport payload.

## 23. AVAudioEngine can abort the simulator before Swift handles an error
**What happened**: The Xcode beta simulator aborted inside `AURemoteIO::Initialize` while `AVAudioEngine.inputNode` initialized. The process terminated before `engine.start()` could throw, so the navigation UI test crashed even though it was not testing audio.
**Resolution**: Make simulator capture and playback explicit unsupported paths that log and return without touching `AVAudioEngine`. Keep audio proof on physical devices.
**Decision**: Simulator UI tests may validate navigation and state, not microphone or speaker behavior. A crash below the throwable API boundary needs a compile-time environment guard.

## 24. Xcode cloned simulators are not a stable test destination
**What happened**: Xcode beta intermittently failed a cloned test device with `NSPOSIXErrorDomain Code 3`; the test never executed.
**Resolution**: Run final tests against the explicitly booted simulator UUID with `-parallel-testing-enabled NO` and fresh DerivedData.
**Decision**: Treat clone-launch failures as infrastructure failures only after the same test passes on a named booted simulator.

## 25. Background audio needs an explicit platform lifecycle
**What happened**: Working foreground audio did not prove that a guide or guest could lock the phone during a tour.
**Resolution**: Add iOS audio background mode and an Android foreground service whose type matches guide microphone capture or guest media playback. Start and stop it from authoritative listen state.
**Decision**: Transport sockets do not grant background execution. Model the ongoing audio role using each platform's supported lifecycle mechanism.

## 26. A file signature is not a valid archive fixture
**What happened**: Early offline-map tests used only the nine-byte PMTiles magic/version prefix. The validator passed data that no renderer could use.
**Root cause**: The test asserted identification, not structure or rendering.
**Resolution**: Validate the complete 127-byte v3 header, section bounds, counts, compression, tile type, and zoom range. Replace the prefix fixture with a complete one-tile archive and render it through MapLibre.
**Decision**: Binary-container tests must include one complete minimal container and a renderer or parser roundtrip. Magic-byte tests cover rejection only.

## 27. Java `File.toURI()` is not a MapLibre PMTiles URL
**What happened**: Android generated `pmtiles://file:/data/...`; the physical MapLibre snapshot never completed. MapLibre requires `pmtiles://file:///data/...` for local byte-range reads.
**Root cause**: Direct interpolation of `File.toURI()` preserved Java's one-slash `file:/...` spelling under the additional `pmtiles://` prefix.
**Resolution**: Build `pmtiles://file://` plus the percent-encoded absolute URI path. Add an exact URL assertion and a physical Pixel snapshot test that verifies the rendered tile color.
**Decision**: Validate nested/protocol-prefixed URLs as exact strings against the consumer's documented grammar; URI objects that are valid alone may be invalid after prefixing.

## 28. Sensor metadata is not presentation state
**What happened**: The first bearing snapshot included guide compass accuracy and sampling time even though the product allows only the selected bearing to cross the wire.
**Root cause**: Local UI diagnostics were modeled beside the authoritative shared value and then serialized together.
**Resolution**: Reduce the bearing payload to 14 bytes: state version, magnetic reference, selected angle, and visibility. Keep accuracy and timestamps in platform guidance services and scan shared modules for their field names in the verification gate.
**Decision**: Shared state contains only what another device needs to reproduce the product action. Diagnostics stay local unless the product explicitly requires them.

## 29. A loading state must not hide a permanent sensor failure
**What happened**: A missing or unreliable compass left the pointer UI saying “Reading compass…” indefinitely because both conditions produced a nil heading.
**Resolution**: Preserve an explicit unavailable/unreliable sensor state and render it separately from initial acquisition. Poor but usable accuracy remains visible as a warning.
**Decision**: Every asynchronous hardware state needs distinct acquiring, ready, degraded, and unavailable representations when those states require different user action.

## 30. Role permissions belong at the action that needs them
**What happened**: Android requested microphone and Wi-Fi Aware access during application launch, even for guests who only listen over the local LAN.
**Resolution**: Start LAN discovery immediately, request microphone access only when creating a megaphone, location only for local map guidance, and nearby Wi-Fi only for the isolated lab. Disable Android cloud backup for tour data.
**Decision**: Do not aggregate optional role permissions into a launch gate.

## 31. An Activity is not a session lifetime
**What happened**: Rotating or recreating Android `MainActivity` called its teardown path and ended the active tour because networking and audio state were Activity-owned.
**Resolution**: Move the runtime graph and its coroutine scope to `ComeOverHereApp`; make the Activity a UI client of that stable process-level state. Add a physical `ActivityScenario.recreate()` test.
**Decision**: Long-running product sessions belong to the application or a service, never to a replaceable screen instance.

## 32. An experimental API must not set the product compatibility floor
**What happened**: The isolated iOS Wi-Fi Aware lab raised both the app and session package minimum from iOS 17 to iOS 26.4.
**Resolution**: Mark lab-only types as iOS 26.4, guard their UI entry, restore the app and package to iOS 17, and enforce the baseline in the full verifier.
**Decision**: Optional capability checks belong around the optional feature; production compatibility is set by production requirements.

## 33. Active state does not navigate a compact split view automatically
**What happened**: Creating a tour updated `activeChannelID`, but iPhone stayed on the channel list because `NavigationSplitView` had no compact-column binding.
**Resolution**: Bind `preferredCompactColumn` to the active session: detail while a guide or guest session is active, sidebar after leaving.
**Decision**: On compact layouts, test the state-to-navigation transition directly; updating the detail model is not navigation.

## 34. Payload delivery does not define which screen is visible
**What happened**: Slides arrived and rendered, while target and bearing payloads also arrived but stayed hidden behind the visible slide. The UI had an inferred slide-first priority rule and the protocol had no authoritative foreground selection.
**Root cause**: Shared content state and shared screen state were treated as the same concern. Live payload order and late-join snapshot order could therefore produce different visible results.
**Resolution**: Add a versioned Slides/Map/Pointer shared-screen snapshot, apply it on both guests, and send it last during late-join restoration. Keep the content snapshots independent.
**Decision**: If a remote action changes what another device should display, transmit that choice as explicit recoverable state rather than reconstructing it from event order.

## 35. Transport lane wrappers do not establish a transport
**What happened**: Authenticated iOS Wi-Fi Aware audio, control, and asset lane classes and hybrid route tests existed, but the normal app still failed without infrastructure Wi-Fi.
**Root cause**: The only iOS `NetworkListener` and `NetworkBrowser` using Wi-Fi Aware belonged to the diagnostic lab. Production never instantiated the lane wrappers and had no owner for pairing, the initial Aware connection, accepted connections, or reconnect.
**Resolution**: Separate connection ownership from lane framing explicitly in the plan. Do not promote Aware until the isolated physical probe passes; then add one production owner that supplies established connections to the existing lane implementations.
**Decision**: A transport integration is incomplete until a production call-site audit proves discovery/connection ownership, data-plane establishment, framing, service wiring, and lifecycle are all reachable from the product flow.

## 36. “BLE cannot stream audio” was too broad
**What happened**: Earlier work attempted raw or unsuitable BLE audio paths and concluded that BLE was control-only. Later source review found protocol-compatible iOS and Android bitchat implementations that send 16 kb/s AAC live voice through a controlled BLE relay graph.
**Root cause**: The earlier conclusion combined a failed L2CAP attempt, raw-audio bandwidth, and an unstructured GATT design into a universal statement about compressed expiring voice.
**Resolution**: Keep BLE's limited bandwidth as a hard constraint, but test a purpose-built realtime format with compression, sequence numbers, expiry, bounded queues, controlled fan-out, and no late retransmission.
**Decision**: BLE voice is a gated degraded fallback, not a capacity assumption. If physical latency, loss, background, thermal, or queue tests fail, BLE remains control-only.

## 37. A documented Android hotspot API is not a stable product network
**What happened**: Android LocalOnlyHotspot/Wi-Fi Direct could be created in code, but physical use destabilized the target device's Wi-Fi behavior.
**Root cause**: API availability did not guarantee reliable coexistence with the device's current Wi-Fi state, firmware, and other radio modes.
**Resolution**: Remove Android-hosted Wi-Fi from the selected production direction. Preserve it only as legacy code until the replacement architecture passes and cleanup is separately authorized.
**Decision**: A phone-hosted network becomes a product dependency only after repeated physical lifecycle, coexistence, reconnect, and background tests on the supported device matrix.

## 38. Speculative radio work must not block transport-neutral product debt
**What happened**: The first plan put the 35%-risk Wi-Fi Aware lab before encoded, sequenced, encrypted realtime framing that could be completed and proven on the working LAN path.
**Root cause**: Phase order followed the desired future transport rather than dependency order and certainty.
**Resolution**: Move realtime compression, framing, expiry, and route-independent encryption immediately after the baseline checkpoint. Run the Aware lab only after the working product has that foundation.
**Decision**: Execute certain transport-neutral improvements before speculative radio integration when the radio depends on the improved protocol but the protocol does not depend on the radio.

## 39. Runtime radio limits require explicit overflow behavior
**What happened**: The target Pixel reported eight maximum NAN data paths while the plan listed Aware group gates above eight without defining what happened to the next guest.
**Root cause**: Aggregate tour capacity and one transport's direct-peer capacity were treated as the same number.
**Resolution**: Stop Aware admission at runtime capacity and route each overflow guest to LAN, then validated BLE voice, then explicit control-only mode.
**Decision**: Every runtime capacity limit needs a user-visible capacity-plus-one behavior before scale testing. Never silently overcommit the radio or count a control-only guest as receiving audio.
