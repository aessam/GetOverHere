# Lessons Learned

## 2026-09-04 — Editable admission is not a media-key rotation

The former tour code derived all three media-lane credentials. Reusing it as an editable room lock would invalidate connected guests; advertising it for open joining would reveal media keys to passive observers. ADR-052 separates admission from the existing group credential and tests that lock/edit/unlock never reconfigures media lanes.

Physical verification also exposed two test assumptions: a SwiftUI toggle accessibility container is not the switch's tap target, and ending a local tour does not imply an empty neighborhood. Target the inner switch and assert local termination instead. Per-platform native codec loopbacks still do not prove cross-platform audio: live Pixel logs received an authenticated iPhone frame but then failed decoding and crashed in MediaCodec cleanup. Keep that failure explicit until a real cross-platform regression test passes.

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

## 40. `Data` offsets are not guaranteed to restart at zero
**What happened**: The first Swift PCM frame accumulator removed emitted bytes, then used integer ranges starting at zero for the next `Data.subdata(in:)`. A later append trapped because `Data.removeFirst` advanced the collection's start index.
**Root cause**: Byte offsets were treated as collection indices after mutation.
**Resolution**: Extract each complete frame with `prefix`, copy it into a rebased `Data`, then remove that frame. The focused Swift and Kotlin accumulator/jitter tests cover split and coalesced capture chunks.
**Decision**: Use collection indices or prefix/drop operations for mutable `Data`; never assume `startIndex == 0` after slicing or removal.

## 41. A security invariant must include dormant transport writers
**What happened**: LAN audio, control, and assets were migrated to encrypted GOH2 v3, but source review still found raw audio writers in inactive Wi-Fi Aware and Multipeer implementations. A later route-selection change could have restored plaintext without touching the working LAN code.
**Resolution**: Seal the supported Wi-Fi Aware control and asset lanes, disable unqualified Aware and Multipeer audio, and add a reusable source audit that enumerates every production payload transport.
**Decision**: Dormant compiled transports fail closed. A no-plaintext claim requires both wire tests and a source-level writer audit.

## 42. Realtime expiry cannot compare unsynchronized phone clocks
**What happened**: The first encoded LAN integration stamped a 500 ms absolute wall-clock expiry on the guide and compared it directly with the guest's wall clock. Device clock skew could make every otherwise valid frame appear expired.
**Resolution**: Use each device's monotonic clock and map the sender timeline to receiver-local time from the minimum observed clock offset. Only network and queue delay above that baseline consumes the frame lifetime. Swift and Kotlin tests use a deliberately large clock offset and still expire excess delay deterministically.
**Decision**: Cross-device realtime deadlines require clock-offset compensation or receiver-local residence time. Never compare raw device clocks directly.

## 43. Handshake timeouts must end with the handshake
**What happened**: The iOS guest control and asset sockets kept their five-second handshake receive timeout after authentication. A quiet guide therefore disconnected every iOS guest even though the session remained valid.
**Root cause**: The guest path installed the timeout before authentication but did not clear it before the long-lived application read loop. The matching Android and iOS audio paths already reset their handshake-only timeout.
**Resolution**: Clear the socket receive timeout immediately after guide authentication and cover the behavior with an idle control-lane regression test.
**Decision**: Every temporary socket option must have an explicit lifecycle boundary and a test that crosses that boundary without traffic.

## 44. A supported Android API floor requires lint in the main gate
**What happened**: Android unit tests and the APK build passed while two offline-map reads required API 33 with a declared API-26 minimum. Production also instantiated the unqualified Wi-Fi Aware session path despite ADR-025 and the open physical P1 gate.
**Root cause**: The verifier compiled the app but did not run Android lint or enforce the production Aware call-site boundary.
**Resolution**: Replace `InputStream.readNBytes` with a bounded API-26 reader, isolate the Aware experiment behind an Android-14 lab boundary, remove production Aware from the application graph, and add lint plus a source call-site audit to the verifier.
**Decision**: The supported Android minimum and experimental-feature boundaries are executable gates, not documentation-only claims.

## 45. Discovery disappearance is not authenticated session end
**What happened**: Bonjour/NSD record removal immediately erased the active guest session and credential, so a transient multicast or interface failure bypassed reconnect entirely.
**Root cause**: The discovery plane was allowed to synthesize an authoritative session lifecycle event even though it had no authenticated evidence that the guide ended the tour.
**Resolution**: Add a non-terminal `channelUnavailable` event, preserve active-session state through discovery loss, and deliver terminal shutdown as an authenticated encrypted `leave` frame that is flushed before guide socket closure.
**Decision**: Discovery controls reachability hints and browse-list membership. Only the authenticated session transport controls terminal remote-session state.

## 46. Bounded replay memory still needs an unbounded monotonic floor
**What happened**: Replay protection remembered only the latest 4,096 accepted frame digests. A valid old ciphertext became acceptable again after FIFO eviction, and the received protocol-minor byte was discarded before AAD reconstruction.
**Root cause**: Memory eviction removed both duplicate detail and all knowledge that the sequence had already passed. Header authentication also used a local constant instead of the wire value.
**Resolution**: Track a monotonic highest sequence and sliding accepted-sequence window per session/sender/stream, reject anything below its floor, and authenticate/preserve the received minor version.
**Decision**: Evict detailed replay records, never the monotonic boundary. AAD must be reconstructed from received authenticated header fields, not local defaults.

## 47. Blocking reads and fan-out writes need different ownership
**What happened**: iOS blocking socket loops occupied cooperative-pool workers, while one serial writer on each platform let a stalled guest block every listener. Queued raw descriptors could also survive shutdown and target a later reused descriptor.
**Root cause**: Connection lifetime, read execution, realtime processing, and multi-client fan-out shared task/queue ownership instead of being isolated per responsibility and per peer.
**Resolution**: Move blocking iOS reads to dedicated queues, wrap descriptor lifetime with a generation, add one bounded deadline-enforced writer per peer on both platforms, and move iOS encode/seal to a dedicated worker. Add 24-guest and stalled-peer regressions plus a source audit.
**Decision**: Blocking reads never run on Swift's cooperative pool. A peer owns its writer and socket lifetime; no fan-out closure retains an unowned raw descriptor.

## 48. LIVE state must be committed after capture setup
**What happened**: iOS treated converter creation and audio-engine startup as best-effort operations. A converter failure forwarded hardware-format bytes as PCM16, while an engine-start failure left the channel advertised as LIVE with no capture stream.
**Root cause**: Audio setup returned an `AsyncStream` even when its required resources were unavailable, so `ChannelService` had no failure signal with which to roll back the partially created guide session.
**Resolution**: Make capture setup throwing, require the hardware-to-wire converter, remove the raw-buffer fallback, and roll back transports, session state, and the advertised channel when setup fails. The verifier rejects the old fallback pattern and the simulator proves capture failure is explicit.
**Decision**: A guide session is not active unless its capture pipeline is configured and running. Required format conversion never degrades to bytes with a different format.

## 49. Socket shutdown and session-secret destruction are different lifecycle events
**What happened**: Terminal tour shutdown closed sockets but left the credential inside audio, control, asset, hybrid, and Aware transport configurations.
**Root cause**: One `stop()` operation represented both transient reconnect and terminal session end, so it preserved the configuration needed by one case in the other case as well.
**Resolution**: Add a required `clearSession()` boundary that stops transport activity and erases credentials and derived sealing state. Keep `stop()` for transient socket lifecycle only.
**Decision**: Secrets follow the logical session lifetime, not the object lifetime. Every terminal path must use explicit erasure; reconnect may retain credentials only in the session owner.

## 50. A contract ADR is done only when every path has its own test
**What happened**: ADR-033 was marked accepted while half implemented. The Swift error carried only the remote major, Kotlin plaintext decode threw the untyped base exception, and the guest UI rendered `CONNECTION FAILED` for a version mismatch while only guide stages showed `tourFeatureError`.
**Root cause**: No per-path checklist. The plaintext and sealed decode paths, the nine transport catch sites, the guide UI, and the guest UI were each assumed covered by the one sealed-path test.
**Resolution**: `SessionProtocolError.unsupportedMajorVersion(received:supported:)` on both decode paths, `UnsupportedSessionVersionException` from Kotlin plaintext decode, every catch site binding both majors from the decoder, one `versionMismatchMessage` builder per `ChannelService`, and a pure guest-status presenter on each platform fed by that builder in tests.
**Decision**: A contract ADR lists every decode path, every transport catch site, guide UI, and guest UI, each with its own test, before it is marked accepted.

## 51. Only UTF-8 byte order is wire order
**What happened**: Swift ordered and deduplicated manifest IDs by canonical Unicode equivalence and Kotlin ordered them by UTF-16 code units, so two builds could encode the same manifest with different bytes and Swift could reject a manifest Kotlin accepted.
**Root cause**: Neither Swift `String` `<`/`==` (canonical scalar order and equivalence) nor Kotlin `compareTo` (UTF-16 code-unit order) is the order of the UTF-8 bytes that go on the wire. Fixtures used ASCII IDs with unique `order` values, which cannot expose either divergence.
**Resolution**: Both cores sort by `(order, UTF-8 bytes)` with an unsigned byte comparator and dedup on exact bytes; `AssetManifestPayload` got the same rule. Fixtures now carry a U+FF5E/U+1F5FA pair sharing an `order`, an NFC/NFD pair, a `z`/`é` pair (signed-byte trap), and an `a`/`ab` pair (prefix trap), with the same golden hex on both sides.
**Decision**: Every cross-platform ordering rule needs a non-ASCII, tie-breaking fixture whose golden is generated from both CLIs and diffed, never written by hand.

## 52. A comparison inside `[[ ]]` cannot fail on a crashed command
**What happened**: `if [[ "$(cli a)" != "$(cli b)" ]]` in the verifier would pass when both CLIs crashed, because `errexit` is suspended inside a condition and empty equals empty.
**Root cause**: Command substitution inside a test expression discards the exit status; the gate only looked at the two strings.
**Resolution**: Every fixture output is assigned to a variable first (so a non-zero exit fails `errexit`), guarded with `[[ -n ]]`, and only then compared; the same shape now covers `state`, `auth`, `handshake`, `realtime-fixture`, and all cross-decodes.
**Decision**: Verifier comparisons never inline `$(...)` inside `[[ ]]`. Assign, guard for non-empty, then compare.

## 53. A per-tour code is a password, not a key
**What happened**: The 10-character tour code (32-symbol alphabet, 50 bits) was turned into the session key with a single HMAC-SHA256 whose salt was the public Bonjour service name, so one captured handshake allowed an offline brute force at GPU speed in about a day.
**Root cause**: ADR-023 treated the short code as key material and reused the HKDF-style extract that suits high-entropy inputs; the confidentiality claim in ADR-030 inherited that bound unexamined.
**Resolution**: PBKDF2-HMAC-SHA256 with 600,000 iterations and a session-bound salt on both cores, sealed protocol major 4 so a legacy peer is an explicit version mismatch, known-answer fixtures on both sides computed independently in Python before either core changed, a normalization-before-stretch assertion, and `derive` moved off the main thread behind a `sessionAttempt` guard because a real stretch is user-visible (0.150 s on the simulator, 1,545 ms on the API 36 arm64 emulator through BouncyCastle).
**Decision**: Any secret a human types is stretched before it becomes a key; the stretch parameters are wire-contract constants with cross-platform known-answer tests, and every known-answer input set includes one non-normalized code so normalization order is pinned. The 50-bit entropy bound stays documented until the QR 128-bit credential ships. P3 physical item: measure `derive()` on the oldest supported iPhone and the slowest Android target; if Android exceeds ~1.5 s the owner revisits the iteration count, which regenerates every credential-derived fixture.

## 54. A lane that can lose the guide must be able to say so
**What happened**: A guest whose realtime socket died stayed CONNECTED and mute until the control lane also failed; the guest audio handler was nil'd and the read-loop exit only logged on both platforms.
**Root cause**: Only the control lane owned reconnect, so the audio lane had no event to raise and no consumer for it. The iOS startup race (`.connected` cancels the reconnect task) meant even an emitted event could have been cancelled by the control handshake.
**Resolution**: One `.failed`/`Failed` per guest run on transport loss with run guards (`!socket.isCancelled` captured before `close()`, `isRunActive(epoch)` + `emitFailedOnce`), routed through the control-lane handler; `pendingAudioLaneFailure` on iOS for the CONNECTING/RECONNECTING race (a refused audio connect during a reconnect cycle must not be discarded either); a five-strike terminal cap (DSCN-19). Wrong codes stay log-only because the guest fails AEAD on the sealed challenge before any hello.
**Decision**: Every lane that can lose the guide reports it through the single reconnect path, exactly once per run, never for a local stop, a version mismatch, or a pre-authentication rejection. A ChannelService-level proof needs a discovered channel; on Android the emulator's NSD provides it, on iOS the G4 injection seam will.

## 55. `flowOn` moves the producer, not the collector
**What happened**: Android encode + seal + fan-out for every 10 ms capture buffer ran on the UI thread.
**Root cause**: `startCapture()` used `flowOn(Dispatchers.IO)`, which only moves the upstream `AudioRecord.read`; `ChannelService` collected on the application scope built with `Dispatchers.Main`, so `plane.sendAudio` and the whole codec path executed there.
**Resolution**: `BroadcastProcessor` on a dedicated `audio-encode-seal` single-thread executor (mirror of iOS ADR-039), `sendAudio` no longer `@Synchronized`; the roundtrip test asserts the encoder thread name set is exactly `{audio-encode-seal}`; the verifier requires both worker labels and rejects a `@Synchronized sendAudio`.
**Decision**: Codec work never runs on a UI dispatcher; the worker label is a verifier-audited contract on both platforms.

## 56. Nagle on a 20 ms voice stream
**What happened**: The realtime lane sent ~150-byte sealed frames every 20 ms over sockets with Nagle enabled while the control lanes already set `TCP_NODELAY`.
**Root cause**: `UDPAudioPlane.swift` set only `SO_REUSEADDR`/`SO_RCVTIMEO`; `UDPAudioPlane.kt` used default sockets. Nagle waits for the previous segment's ACK and the receiver delays ACKs, so small frames were batched.
**Resolution**: `TCP_NODELAY` on the accepted and the connecting descriptor on both platforms; the tests read the option back (`getsockopt != 0`, `Socket.tcpNoDelay`); the verifier requires the literals in both files, one `rg` per file.
**Decision**: Every realtime socket disables Nagle at creation, and the audit checks each file on its own so one file cannot mask the other.

## 57. Playout timing comes from a local clock, never from the network
**What happened**: The jitter buffer drained only when a frame arrived, so a lost frame shortened the timeline instead of being concealed, and the spec's PLC claim was false.
**Root cause**: `popReady` was called from the read loop after every accepted frame, and native Opus/AAC decoders expose no PLC API, so nothing could fill a gap.
**Resolution**: `popForPlayout` on both cores returns `frame`, `conceal(missing)`, or `wait`; `PlayoutClock` ticks every frame duration on its own thread, emits one exact-duration silence frame per concealed sequence, resyncs above the target depth, decodes only on that thread, and reports a decoder failure once. The `playout` CLI fixture (`w,w,f1,f2,w,c3,f4,f10,f11,w`) is a verifier gate; transport tests drive `tick()` with a fixed clock.
**Decision**: Clocked playout with silence concealment is the contract; timer-versus-DAC drift is a documented limitation bounded by the jitter cap and surfaced by short-write counters, to be measured physically in P3.

## 58. The ~100 ms tap floor and the ignored `AudioTrack.write` result
**What happened**: `AudioEngine.swift` claimed a ~7 ms capture tap, and `AudioEngine.kt` discarded the return value of `AudioTrack.write(..., WRITE_NON_BLOCKING)`.
**Root cause**: `installTap(bufferSize: 345)` is a request; AVAudioEngine's input tap delivers ~100 ms buffers regardless. A non-blocking `AudioTrack.write` returns the bytes accepted, so a full buffer (timer-versus-DAC drift) or a dead track returned 0 or a negative code that nobody read.
**Resolution**: Comment corrected (DSCN-5, no rework this round); `PlaybackWriter` write loop with `Written`/`Short`/`Failed` outcomes, JVM-tested over an injected sink because `AudioTrack` cannot be built on the JVM; short writes counted and logged, errors surfaced once per playback run into `tourFeatureError`.
**Decision**: The ~100 ms tap floor is a P3 physical measurement item included in mouth-to-ear; every audio-hardware write result is inspected and counted so drift is observable before it is audible.

## 59. Publish nothing you cannot yet capture
**What happened**: iOS appended the channel, set `.broadcasting`, and published Bonjour before the audio lane and the microphone started, and a failed start never withdrew the record; Android committed `BROADCASTING` and published NSD after the control and asset lanes but before the audio lane and capture, and the microphone `SecurityException` was thrown inside the collector coroutine where the startup `try` could not see it.
**Root cause**: Lane start reported failures only as asynchronous `failed` events, and both guides drop those because `handleControlConnectionEvent` is guarded on the guest listen state; the commit block sat in the middle of the sequence instead of at the end.
**Resolution**: Synchronous throwing lane start on both platforms (`startGuide() throws`, `startBroadcasting throws`, `IllegalStateException`, synchronous Android microphone preflight), commit and publish as the last step, a rollback that clears every lane and broadcasts `channelEnded`, and fakes behind small interfaces so the ordering is asserted on the simulator and the JVM (ADR-046).
**Decision**: Startup is a sequence of throwing calls with one catch; the state commit and the discovery record are the last two lines of that sequence, never earlier.

## 60. Discovery is not allowed to end an authenticated session
**What happened**: An unauthenticated NSD/Bonjour announce that changed `audioHostIP` for the active channel called `joinChannel` on both platforms, which ran `stopCurrentActivity` → `clearSession`, erased the admitted credential, reset the reconnect counter, and paid a second PBKDF2 stretch.
**Root cause**: The address-change path reused the user-facing join entry point instead of the transport-level stop + reconfigure that the reconnect timer already used; ADR-036 was only half implemented.
**Resolution**: `restartGuestTransports(channel:)` on both platforms: cancel the reconnect, `stop()` the three lanes and playback, and restart them with the retained credential; the reconnect timer uses the same function with the freshest discovered address; `clearSession` calls stay at zero across an address change (`guideAddressChangeReconfiguresWithoutClearingSession` on both platforms).
**Decision**: Discovery may reconfigure where the lanes connect; only an authenticated leave, an explicit user action, or a terminal failure may erase credentials.

## 61. A wrong code is not a lost connection, and End Tour must not wait on the main thread
**What happened**: A wrong tour code surfaced as the generic transport failure and was retried five times (about 31 s) on both platforms; version mismatch and reconnect exhaustion set `.failed` but left credentials inside the transports; End Tour blocked the main actor for up to 2 s on the leave semaphore; iOS had no termination path that cleared the lanes.
**Root cause**: One `failed` event carried every handshake outcome, so the product could not tell "the guide rejected my code" from "the socket closed"; the bounded leave wait ran on the main-actor class; `AppCoordinator.stop()` was never called and only stopped the audio plane.
**Resolution**: A typed `credentialRejected` event sourced only from the AEAD failure or the proof mismatch (Kotlin gained `SessionFrameAuthenticationException` so classification is by type, not by message text, DSCN-26); one `failGuestSession` path for every terminal guest outcome that erases credentials; `sendLeave()` waits off the main actor with the same 2 s deadline and the lanes are cleared after delivery under a dedicated lane-ownership `sessionGeneration` guard; `terminate()` plus `willTerminateNotification` on iOS with the synchronous bounded flush (ADR-048). The first cut reused the DSCN-20 `sessionAttempt` for that guard; because every no-op `leaveChannel()`/`terminate()` and every invalid `joinChannel` also bumps it, a second End Tour tap inside the flush window skipped the deferred teardown and left the lanes listening with the ended credential. A guard must be bumped only by the events it is meant to detect.
**Decision**: Events name the mechanism (`credentialRejected`, `versionMismatch`, `failed`), never a message to parse; every terminal guest outcome goes through one function that erases credentials; the only main-thread wait is the process-termination flush.

## 62. "Listeners" counted the audio lane only, and the audio session never told the product anything
**What happened**: The guide UI showed one count fed by audio-lane joins while control-lane guests were invisible; the guest's speaker override showed the word "Speaker" with no warning although it feeds tour audio back into the guide's microphone; iOS route and configuration observers only logged and the converter was never rebuilt, and there was no interruption observer; Android never requested audio focus and ignored `ACTION_AUDIO_BECOMING_NOISY`.
**Root cause**: `TourControlService` ignored `guestDisconnected`, so no control-lane membership existed to count; the audio engines treated the system audio session as fire-and-forget.
**Resolution**: `connectedGuestCount` with set semantics keyed by participant (re-registration arrives as disconnect + join), rendered as `"<n> connected · <m> audio"`; `speakerFeedbackWarning` while listening on the loudspeaker; iOS `installCaptureTap` extracted so the converter is rebuilt on a route or configuration change, an interruption observer that pauses/resumes/stops through the pure `interruptionAction(for:)`, and an ended stream surfaced as `"Microphone capture stopped"` with the lanes kept up (DSCN-12); Android `AudioFocusRequest` for voice communication, becoming-noisy receiver that forces private output, and `"Another app took over audio"` on focus loss.
**Decision**: Counts are per lane and named by what they measure. The iOS route/interruption behavior is verified only through the pure decision functions in `AudioEngineTests`; headset plug/unplug and an incoming call are P3 physical checklist items because AVAudioEngine capture is unsupported on the simulator by design. The Android focus and becoming-noisy paths run as the instrumented `AudioEngineFocusTest`; the earpiece-route assertion is skipped where the platform exposes no earpiece (emulators), and the broadcast receiver delivery itself (the test calls the handler directly) is the headphone-unplug physical check.

## 63. Every accepted socket was a free worker for five seconds
**What happened**: All four accept loops (control and asset on both platforms, realtime on both) dispatched a handshake worker with a 5 s receive timeout for every accepted socket with no cap, so silent connections could pin unbounded queues or threads on the guide.
**Root cause**: Admission was bounded only by time (the receive timeout), never by count.
**Resolution**: A per-lane bound on pending handshakes, acquired in the accept loop and released when the handshake returns or throws; the connection beyond it is closed before a byte is written, with one log line (ADR-047). `HandshakeBoundTests`/`HandshakeBoundTest` failed before on both platforms (the connection beyond the bound received the challenge's first length byte) and pass after. The first bound of 8 broke the 24-guest burst test because a simultaneous join is accepted faster than it authenticates; the bound is 32, calibrated above the largest tour group.
**Decision**: Unauthenticated work is bounded by count and by time on every lane, and the count is calibrated against the product's group size, not picked as a round number. Release on the receive-timeout path is by construction (the same release covers every throw) and is not separately timed in the gate because it would add more than 5 s per lane per platform.

## 64. A local cache integrity error must not abort the transfer loop
**What happened**: One length-mismatched `complete/` entry threw from `readyURL`/`readyFile` inside the guest's manifest loop, so every later asset was never requested and no FAILED status was sent; a checksum mismatch was terminal with no re-request; every missing asset was requested at once against a per-peer writer of capacity 8; iOS logged asset failures without surfacing them and neither guest screen rendered `tourFeatureError`. Extending the loopback test to four assets with a corrupt map entry produced zero ready assets on both platforms.
**Root cause**: The cache reported repairable local-integrity conditions as thrown errors into a loop with no per-asset isolation, and the guest had no request scheduler, so the only bound on outstanding requests was the pack size.
**Resolution**: The cache repairs and reports by return value (delete, one stderr line, `nil`/offset 0); per-asset isolation; an in-flight cap of 2 with an ordered pending queue; one bounded re-request on checksum mismatch; a per-hash 15 s inactivity deadline that reports FAILED and frees the slot (DSCN-16), because the guide has no failure frame for a request it cannot answer; reset on disconnect/stop; iOS `tourFeatureError` surfacing and a guest-side error label on both platforms (ADR-049). Kotlin classifies the checksum failure by exception type (`AssetChecksumMismatchException`), never by message text, mirroring DSCN-26.
**Decision**: Local cache repair is deterministic and logged, never a thrown loop-aborting error; every terminal asset outcome (READY, FAILED, expired) sends its status and releases its slot; a cap on outstanding work always ships with a deadline that releases it.

## 65. Tests thinner than their names
**What happened**: The 24-guest test asserted the join set only; stalled-peer isolation was proven only at writer level on socketpairs; no test forged a sender ID, looped reconnects, or admitted 24 Android guests; `BoundedSocketFrameWriterTest` asserted inside the writer's daemon thread, where a thrown `AssertionError` never reaches JUnit (the probe in ExperimentLog G6 item 8 passes the old test with `Healthy writer failed` only on stderr); `AudioEngineRoutingTest` checked Float32 alignment on a PCM16 path; the `ListenerOutput` tests never read the engine's default. Writing the new tests surfaced three more facts: (1) the Kotlin transport reports a guide restart at the guest as `Failed("Session: guide connection failed: socket closed")` before `Disconnected` (its guest catch does not exclude `EOFException` the way the guide side does) and reports the eviction of a stalled peer at the guide as `Failed("Session: guest connection failed: Socket closed")` (the reader thread's `SocketException` on the writer-closed socket), while iOS emits neither; both are pinned as exact expectations and left unfixed (out of G6 scope, a product wart for the next round). (2) On iOS, timing out an `AsyncStream` consumer to prove silence finishes the stream for the rest of the test, so the reconnect test read `.streamEnded` right after its 250 ms window; a negative wait must poll a recorded log. (3) The critique's `SO_REUSEADDR` mutation does not discriminate on the JVM because `ServerSocket` enables it by default; the discriminating Kotlin mutation is leaving the listener open in `stop()` (`Address already in use`). On iOS the same `SO_REUSEADDR` removal does discriminate: the reconnect test fails on the first restart with `.bindFailed("Session: bind/listen failed: Address already in use")` (`LocalSessionTransportTests.swift:790`), and the port-50_036 reuse in `terminalLeaveArrivesBeforeShutdown` fails the same way.
**Root cause**: Tests were named after the ADR-038/ADR-039 invariants but asserted only the setup step, and assertions were placed on threads the runner does not observe.
**Resolution**: A raw authenticated test client on both platforms (`RawGuestClient`), transport-level fan-out, stalled-peer, forged-sender, reconnect-loop, and Android multi-guest tests; JUnit-thread assertions; the PCM16 10 ms contract assertion; engine-default assertions on both platforms (`AudioEngine.DEFAULT_LISTENER_OUTPUT`, `AudioEngine().listenerOutput`).
**Decision**: A test name is a claim; the assertion must be able to fail for exactly that claim, shown by a recorded mutation, and assertions never run on threads the runner does not observe. A negative wait on iOS polls a log, never a stream.

## 66. A gate hardcoded to one machine is not a gate
**What happened**: `verify_tour_session.sh` hardcoded `/Users/aessam/Downloads/Xcode-beta.app` and the Android Studio JBR path and ignored `JAVA_HOME`; no CI ran the cross-language byte parity, so parity depended on one person remembering a ten-minute script; the plaintext-path audit named `MultipeerAudioPlane.swift` by path, and an `rg` over a missing path exits 2, so the audit would have passed silently the day the file was deleted.
**Root cause**: Environment discovery was never separated from the gate logic, and audits assumed the files they guarded still existed.
**Resolution**: Env-first defaults with the previous paths as the last fallback in all five scripts (`GOH_*`, then `JAVA_HOME`/`DEVELOPER_DIR`, then `xcode-select -p`/JBR), the resolved toolchain printed before the preflights, an existence audit over the retired paths and the entitlement (proved by touching a retired path: exit 1), `scripts/verify_core_parity.sh` as the reusable locally runnable core gate, and `.github/workflows/core-parity.yml` on `push` to `main`, `pull_request`, and `workflow_dispatch` (ADR-051). The first CI run could not be triggered this round because the branch was not pushed (no-push rule); the exact commands are recorded as BLOCKED in ExperimentLog.
**Decision**: Every gate resolves its toolchain from the environment first and fails loudly on absence; an audit over a file that may be deleted is an existence check, never a content match; parity of the shared cores runs on every push to `main` and every pull request, and the full gate stays local and physical.

## 67. Startup errors must render outside the active-tour view
**What happened**: A failed guide startup rolled back every lane and saved `tourFeatureError`, but users returned to the channel list without seeing the reason.
**Root cause**: Both platforms rendered the error only inside a view requiring an active channel, while rollback correctly cleared that channel. Service-state tests did not prove visibility.
**Resolution**: Render the failure reason on the channel list when no tour is active and the connection state is failed. UI regression tests exercise real simulator capture failure on iOS and real control-port bind failure on Android.
**Decision**: Verify a startup failure at the screen reached after rollback, not only in service state. Gate the banner on failed state so normal leave does not reveal an old tour error.

## 68. Clean-checkout CI and full UI suites expose gaps hidden by local gates
**What happened**: The first hosted parity run failed because `gradle-wrapper.jar` was missing. The full emulator UI suite asserted navigation before asynchronous tour startup finished, and hardware-only routing/capture assertions failed on virtual devices.
**Root cause**: A global `*.jar` ignore rule hid the locally installed wrapper. Compose idleness did not await PBKDF2 startup. The existing local verifier ran iOS unit/integration tests but did not run the complete UI or emulator suites.
**Resolution**: Regenerated and committed the Gradle 8.13 wrapper, matching its official SHA-256 (`81a82aaea5abcc8ff68b3dfcb58b3c3c429378efd98e7433460610fecd7ae45f`), with a repository ignore exception. Branch pushes trigger CI. Navigation tests wait for CONNECTED; unavailable physical earpiece checks and simulator guide capture explicitly skip. Android capture tests release capture in teardown. `scripts/verify_virtual_devices.sh` composes the host gate, iOS UI suite, and emulator instrumentation.
**Decision**: A local cache is not a build dependency manifest. Test asynchronous completion explicitly and report hardware coverage separately from software failures.

## 69. Same-platform codec roundtrips did not prove cross-platform playback
**What happened**: The Pixel authenticated an iPhone tour and received audio, then failed native decoding and crashed during cleanup. Both platforms' local codec tests had passed.
**Root cause**: Android treated the Apple encoder's opaque magic cookie as Android codec-specific initialization. Cleanup called `MediaCodec.stop()` in an error state, replacing a recoverable decode failure with an uncaught exception. Fixing initialization exposed a second boundary error: Opus output was 48 kHz while the playback engine expected 16 kHz, producing three times the expected PCM byte count.
**Resolution**: Build documented Android initialization from the negotiated voice profile; inspect actual decoder output and resample 48→16 kHz with anti-alias filtering; release native codecs directly and contain cleanup errors in idempotent playout teardown. Retain production Apple-encoded tone fixtures and test both codecs on Android hardware for non-silence, duration, and frequency, plus encrypted transport replay. Add a failing-decode/failing-close unit regression and exact streaming-chunk equivalence tests for resampling (ADR-053).
**Decision**: Test across the actual platform codec boundary. Nonempty decoded bytes alone are insufficient, and transport silence from concealment must not satisfy an audio-delivery assertion. Error cleanup must preserve the original failure without killing the process.

## 70. A Bluetooth source file is not a running Bluetooth discovery path
**What happened**: The user disabled Wi-Fi and the devices disappeared from each other's room lists despite legacy BLE files still existing in both apps.
**Root cause**: Production instantiated Bonjour/NSD-only `LocalControlPlane`; no call site started `BLEControlPlane`. The Bluetooth usage description/runtime permission declarations had also been removed. LAN test success and unused radio code did not establish no-Wi-Fi behavior.
**Resolution**: Add read-only Bluetooth room discovery behind an injected interface in the production discovery owner, restore permission handling, merge observations without losing LAN addresses, and label/disable discovery-only rooms instead of implying that audio works. The old unauthenticated command channel stays unused. Metadata, merge, lifecycle, and UI regression gates are recorded in ExperimentLog.md; physical validation remains pending because the Pixel disconnected and the iPhone was locked.
**Decision**: Prove the selected runtime path with the target radios disabled/enabled explicitly. Treat room visibility, authenticated joining, control delivery, and voice playback as separate gates. Do not infer any of them from the existence of an implementation file or a passed LAN test.

## 71. Reverse codec assumptions need cross-platform evidence, not an automatic rewrite
**What happened**: Review identified that iOS installs Android codec-specific bytes as its native magic cookie, without an Android-to-iOS regression.
**Root cause**: Prior native fixtures tested only Apple encoding into Android decoding.
**Resolution**: Export generated 440 Hz tones through production Android encoders; decode Opus and AAC through production iOS code, checking duration, non-silence and frequency. Both passed on the iOS 26.4 simulator without decoder changes. The first fixture-export harness failed because Gradle uninstalled the app before retrieval; explicit install/instrument/read and strict hex validation corrected the harness.
**Decision**: A compatibility risk is not a reproduced failure. Retain the fixture, test both directions, and change production decoding only when evidence requires it. Set test-process environment explicitly rather than assuming xcodebuild forwards arbitrary shell variables.

## 72. A preview still needs a permission and resource lifecycle
**What happened**: Bluetooth permission fired at app launch and both managers/server roles ran throughout a LAN tour.
**Root cause**: App-owned discovery startup was treated as permission intent and radio ownership, without a distinction between browsing, advertising and listening.
**Resolution**: Explicit foreground preview toggle; role-specific manager/server creation; no scanning for guides or joined LAN guests; stop on background; iOS burst and Android balanced scanning; suppress power alerts and back off radio errors. Service and UI regression tests cover intent and lifecycle.
**Decision**: Permission approval is not permission to scan forever. Read-only previews need bounded resource ownership and must not imply joining/audio capability.

## 73. Nonblocking behavior must survive a full socket
**What happened**: Admission reply writes could block the room-policy lock. The first iOS nonblocking regression itself hung inside `send` while filling a socket pair using `MSG_DONTWAIT` alone.
**Root cause**: A per-send flag was assumed to establish the required behavior without proving it on the target runtime. Android's `soTimeout` also limits reads, not writes.
**Resolution**: Prepare and verify `O_NONBLOCK` on iOS and a nonblocking channel on Android before the locked final send. Reject incomplete AEAD replies instead of retrying under the lock. The simulator full-socket test then completed in 0.006 s; functional lock/edit/unlock still passed.
**Decision**: Backpressure must be exercised, not inferred from a timeout or flag name. Keep the policy-revision check and final send serialized without waiting for peer progress.

## 74. A visible room must not be mistaken for an implemented session
**What happened**: The Bluetooth preview displayed guide rooms while joining was intentionally disabled. That did not meet the user's walking-tour requirement.
**Root cause**: Metadata discovery was delivered without admission and media transport ownership, while broader implementation remained a plan.
**Resolution**: Add native direct byte connections through the existing admitted audio/control/asset lanes; gate Join on an actual local endpoint capability. Add physical fixtures that require all four stages, including non-silent decoded audio rather than a handshake or first-frame log.
**Decision**: Report complete loops and exact remaining platform limits. Direct Android passes do not qualify iPhone, mesh, locked devices or large groups.

## 75. Aware discovery, pairing and data-path security are different contracts
**What happened**: The first Android Aware implementation attempted to advertise a server port without an NDP security configuration. Pixel 7 additionally reported no native Aware pairing support. Initial secured requests then timed out.
**Root cause**: Pairing capability was treated as a prerequisite for every Android data path, and pairing success as sufficient link configuration. The public Android builder explicitly requires security for port advertisement; responder registration must precede subscriber initiation.
**Resolution**: Explicit SK-128 NDP security, matching publish security, and responder-first setup passed the actual two-phone fixture in both directions. Pixel 7 uses PIN-secured legacy NAN instead of unsupported native pairing. Apple system-paired Aware remains a different setup and is not claimed interoperable.
**Decision**: Validate each public API contract and each physical role. A street file transfer in another app does not establish the transport or security scheme available to this app.

## 76. Parallel logical lanes still share one Bluetooth controller
**What happened**: The first BLE physical fixture authenticated audio but missed pointer state; one of three concurrent L2CAP opens failed. A later run delivered control/assets but missed the decoded-audio threshold; passing reruns do not erase that failure.
**Resolution**: Serialize Android L2CAP opens, request high connection priority only while joined, disable Nagle on local adapters, and retain strict non-silent audio assertions. Bound complete sealed-frame queues and close stalled writers rather than accumulating stale speech.
**Decision**: Separate application sockets do not establish radio-level scheduling or group capacity. Keep congestion, locked-device and endurance qualification open.

## 77. A native error code is evidence, not a diagnosis
**What happened**: The user reported iOS Wi-Fi Aware `-11992` after successful installation. The signed app contains both required Aware entitlement values; no physical diagnostic capture was available before the user left.
**Resolution**: Preserve the operation and native code, show retry guidance and the mixed-platform limitation, and regression-test message handling in the simulator. The native root cause remains unresolved.
**Decision**: Do not assign an undocumented code to permissions, unsupported hardware or an OS defect without evidence. A passing simulator error-handling test is not a radio fix.

## 78. Reporting a failed native owner is not sufficient cleanup
**What happened**: iOS Aware caught an owner failure but retained its mode and route caches. A subsequent request for the same mode returned early. Android fatal startup/configuration callbacks similarly reported failure without releasing the owner.
**Resolution**: Tear down the failed owner before reporting; distinguish whole-owner failure from individual peer failure and local cancellation. Cover restart after native failure, unexpected return/cancellation, stale cancelled operations and capability rechecks at the iOS operation boundary.
**Decision**: A dead discovery owner must not leave joinable cached routes. This recovery fix is independent of the native radio failure that triggered teardown.
