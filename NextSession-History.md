# GetOverHere Historical Execution Plan

> Historical checkpoints and original P0–P8 plan, preserved from NextSession.md during the research handoff. These sections contain superseded status statements and earlier action-code meanings. Start with [NextSession.md](NextSession.md) for current implementation status, evidence, research corrections, and execution order. Historical risk percentages are planning guesses, not measured probabilities.

## September 7 Android Aware benchmark checkpoint

Implemented `scripts/benchmark_android_aware.sh` and test-only native fixtures. Run `bash scripts/benchmark_android_aware.sh --guide 66180DLKX006ND --guest 2A111FDH2007A1`; defaults swap guide roles and measure three 10-second trials of each one-way direction and duplex. Every block and both endpoint counters must match. Setup and continuous foreground checks refuse secure-keyguard dismissal. The runner preflights explicit devices, runs emulator regressions, installs exact APKs, captures bounded instrumentation and scoped logs, and fails on incomplete delivery. Do not edit running harnesses.

The first pilot isolated an Android startup failure: unrelated outgoing TCP traffic occupied fixed listener port 50004. The active `WiFiAwareRoomTransport` now allocates a free port and advertises it through native Aware metadata. The occupied-port regression failed before the change and passed afterward. This establishes one cause, not every historical discovery failure or iOS `-11992`.

Final frozen benchmark passed all 18 measured trials: `/tmp/GetOverHere-aware-benchmark-final.log`, artifacts `/tmp/GetOverHereAwareBenchmark.po2lx70k`. Median one-way receiver goodput was 292.46–307.41 Mbps; highest 10-second trial was 326.61 Mbps. Duplex medians were 180.56–185.69 Mbps per direction. Idle RTT p95 was 155.02/171.04 ms with 100 samples; measured duplex RTT p95 reached 234.47 ms. Guest-local four-channel setup was 2.14/3.99 seconds. This is native Aware socket/bridge throughput, not full encrypted voice throughput, group capacity, battery or acoustic latency. Radios remained enabled and infrastructure association was not removed; sockets explicitly use Aware, without LAN fallback.

Full frozen software gate passed: `/tmp/GetOverHere-aware-benchmark-virtual-final.log`, including both platforms, emulator regressions and 100 native cross-provider signature checks. Actual Android tour fixtures also passed both guide directions with `GOH_NEARBY_REUSE_INSTALLED=1 GOH_NEARBY_TRANSPORT=aware` and the explicit guide/guest serials: `/tmp/GetOverHere-aware-dynamic-tour-forward.log` and `/tmp/GetOverHere-aware-dynamic-tour-reverse.log`. These assert admission, control, exact assets and native-decoded audio, not microphone/speaker, deliberate locked operation or endurance. All benchmark and qualification jobs finished; no paid resources were started. Keep the dedicated simulator/emulator for reuse and `stable-local-network` at `59b0402`.

Remaining implementation order: versioned admission delivery and session-lifetime pinning of the guide public key; production sign-once/verify-before-open integration across guide lanes; bounded authenticated relay; per-participant hybrid route recovery and asset scheduling. Then run consolidated physical acceptance. The benchmark's idle latency tail warrants separate diagnosis before attributing delay solely to asset contention. Mixed iOS/Android Aware security and iPhone `-11992` remain unresolved; no iPhone operations are authorized by the two-Android availability statement. Do not request another intermediate user test or call the whole roadmap complete.

## September 7 physical-test restart and admission drain

The user approved restarting CoreSimulator and made both unlocked Android phones available again (Pixel 11 Pro `66180DLKX006ND`, Pixel 7 `2A111FDH2007A1`). Only that identified simulator service was restarted. The iPhone remains unavailable. The share-sheet transfer target is still unidentified; do not infer mixed-platform Aware interoperability from that UI.

The resumed BLE fixture reproduced an admission failure twice: the guide forwarded the 103-byte challenge and 38-byte reply, but the guest received only the challenge before native close. Both guide adapters now allow up to five seconds for the guest to consume the reply and close after the local admission server reaches EOF. Wire bytes and guest behavior are unchanged. A deterministic close regression failed before the Kotlin fix and passed after it; both platforms cover peer completion and the abandoned-peer deadline.

Final software gate passed in `/tmp/GetOverHere-admission-drain-virtual-booted.log`: all host gates, iOS unit/UI, Android emulator instrumentation, and native cross-provider signatures. Explicitly boot the dedicated simulator first: `DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer xcrun simctl bootstatus B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98 -b`. Then run `GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer GOH_IOS_DERIVED_DATA=/tmp/GetOverHereSignatureIOS GOH_IOS_DESTINATION='platform=iOS Simulator,id=B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98' ANDROID_SERIAL=emulator-5554 bash scripts/verify_virtual_devices.sh`. Automatic simulator launch intermittently failed Busy; do not restart shared services again without approval.

Physical BLE passed both guide directions with existing radio settings and again with Wi-Fi disabled before joining. Both Wi-Fi settings were restored and read back as `1`. Android Aware passed both roles in both directions, but a repeat reverse run failed before discovery; keep it intermittent, not qualified stable. A later reverse run passed after `adb -s SERIAL shell input keyevent KEYCODE_WAKEUP` and `adb -s SERIAL shell wm dismiss-keyguard` on the user-confirmed passcode-free phones. Immediate state snapshots still showed keyguard during dismissal; a follow-up foreground read was blocked by approval-review timeout, so do not claim the experiment established the failure's cause. One earlier BLE guide was observed asleep behind keyguard while its fixture ran; KEEP_SCREEN_ON/turnScreenOn alone do not prove foreground conditions.

Resume physical checks with `GOH_NEARBY_GUIDE=SERIAL GOH_NEARBY_GUEST=OTHER_SERIAL bash scripts/verify_nearby_physical_android.sh`; add `GOH_NEARBY_WIFI_OFF=1` for BLE-only disabled-radio setup, or `GOH_NEARBY_TRANSPORT=aware` for Android Aware. After a normal install, `GOH_NEARBY_REUSE_INSTALLED=1` verifies exact app/test APK SHA-256 on both phones before skipping costly reinstalls. It rejects missing, split, unsafe-path or different installed candidates. Never edit an executing harness. All test jobs from this checkpoint have finished; the dedicated simulator/emulator are retained for reuse.

Next: enforce/record actual foreground and keyguard state in the physical fixture, then reproduce Aware discovery with stage-level diagnostics before changing its radio behavior. Continue the separately listed admission guide-key/bootstrap and relay work; do not claim they were completed by this drain fix. iPhone `-11992`, mixed-platform Aware, background/locked acceptance, scale and endurance remain unresolved.

## September 7 signed-guide prerequisite

The Swift/Kotlin cores now contain `GuideFrameSigner`, immutable `SignedGuideFrame`, and `GuideFrameVerifier`. GOS1 carries an unchanged GOH2 v4 sealed envelope and a canonical low-S P-256 signature. Verification requires an externally supplied pinned public key plus the expected session/guide IDs; a packet cannot choose its own trusted key. Host cross-language verification, byte-tamper/truncation tests, and native Android-provider tests are wired into the software gates.

This is ADR-038's signed-frame prerequisite, **not completed app guide authentication or relay**. Next: specify and implement versioned direct-admission delivery of the guide key, bind its lifetime to the tour, reject key changes on reconnect, then wire sign-once/verify-before-open at every production guide lane. Do not accept a key solely from discovery, force codes on open rooms, enable unsigned relay, or claim the native `-11992`/mixed-Aware failure is fixed. Android availability is superseded by the checkpoint above; the iPhone remains out of scope.

## September 6 implementation checkpoint

Follow-up after `8c73fa9`: fatal iOS Aware operations now release cached routes, probes and listeners before reporting failure; the same requested mode can restart. Local cancellation cannot tear down a newer owner, while unexpected native cancellation/return is treated as failure. Android fatal attach/configuration/startup failures release the owner as well; individual peer failures do not disconnect other guests. Five iOS simulator lifecycle regressions exercise the operation boundary, not RF. This does not resolve native `-11992`, mixed-platform link security, or the signed relay roadmap below.

Direct BLE admission, encrypted native voice, control, and assets are implemented through native L2CAP byte connections on both platforms. Native Aware owners are connected to the room UI and the same application lanes. This is a direct-session milestone, not completion of the signed relay/guide-key work below.

Wi-Fi-disabled Android acceptance passed in both directions after adding a four-frame native ACK window. Application queue bounds alone did not prevent stale audio inside the native socket; the strict test reproduced that failure before the fix. Both original Wi-Fi settings were restored and read back as enabled. Reusable harnesses: `verify_nearby_physical_android.sh` (`GOH_NEARBY_WIFI_OFF=1`) and the compiled-but-not-physically-run `verify_nearby_cross_platform.sh` for the unavailable iPhone.

- **A3:** GOD1 fixed-lane selector, GOR1 metadata, capability-aware joining, failed-join cleanup, and endpoint recovery are implemented. Admission remains the existing open/optional-lock protocol. Signed relay and guide-key pinning remain unimplemented.
- **A4:** Complete sealed realtime frames use bounded queues (8 frames, 150 ms queued-audio lifetime, 1 s write deadline), with unchanged receiving authentication/dedup/expiry. Physical Pixel 11 Pro→Pixel 7 and reverse BLE fixtures passed admission, pointer, exact 512-byte assets and 100 non-silent native-decoded frames. Earlier setup/audio failures are retained in ExperimentLog, not erased by passing reruns. No acoustic/endurance/group claim follows.
- **A5:** Android Aware has a working PIN-secured NDP path, including Pixel 7 without native pairing. Apple Aware uses system-paired connections. Those security setups do not implement mixed-platform Aware interoperability; the UI says to use Bluetooth for mixed groups. Direct lane reconnect can re-resolve nearby endpoints and retain admitted credentials. Mesh/hybrid scale and 5/10/50-participant physical acceptance remain outstanding.
- **A2:** Physical testing is paused at the user's request: all phones are unavailable while travelling. Before that pause, the signed iPhone candidate installed successfully, but no automated mixed-platform radio run completed. The user reported iOS `NWError.wifiAware(-11992)`; the signed artifact contains Publish/Subscribe entitlements, but the native failure's cause is unresolved. Continue simulator/emulator checks only; do not contact phones or request repeated unlocks.

The older plan below is preserved as the target; its statements about unowned Aware connections and unavailable Pixel hardware are superseded by this checkpoint. `stable-local-network` remains at `59b0402`; do not move it to this experimental work.

## September 5 review remediation — approved A1–A5 execution

The user approved review remediation, BLE admission/control, BLE voice, and Aware/hybrid routes. On September 5 the user explicitly requested all coding before one consolidated physical feedback round. This supersedes the previous rule that incoming physical gates must pass before implementation: software implementation and integration proceed while phones are unavailable. Physical gates below still control acceptance and product claims; passing software tests does not waive them.

- **A1 — Software remediation:** Reverse Android-to-iOS codec fixtures pass without a decoder change. Explicit foreground Bluetooth intent and role-specific radio lifecycle replace launch-time scanning. Admission completion uses nonblocking sends under the policy lock, fixed leading-zero ECDH tests cover both cores, and the main gate runs cross-language admission. Current spec and CLAUDE onboarding now match open rooms with optional editable locking. ADR-055 and ExperimentLog record the evidence and limits.
- **A2 — Consolidated physical acceptance, deferred until the integrated candidate:** Pixel `66180DLKX006ND` is absent from adb; Dark knight reports `passcodeRequired: true` on September 5. These are acceptance limitations, not coding blockers. Do not repeatedly ask the user to reconnect or unlock devices during implementation. Test fresh locked discovery separately from locking after joining; neither is qualified by the preview.
- **A3–A5 — Remaining implementation:** BLE admission/control and voice, Aware production ownership, and hybrid assets/routes proceed behind explicit experimental capability status. Implement a bounded discovery/link model without assuming an unmeasured seven-central platform limit. Before relay implementation, specify guide-key bootstrap for open rooms without silently imposing mandatory QR or a tour code. Strong short-code resistance to an active malicious guide requires a separately reviewed admission protocol; ADR-052 states the attack explicitly. Group and locked-device qualification remain physical acceptance work.

### Integrated candidate delivery contract

- **A3 — BLE session path:** Implement authenticated direct admission, authoritative control, guide-key pinning and bounded relay behavior; test open/locked/edit/unlock, malformed input, tampering, expiry, topology faults, and cross-language byte parity.
- **A4 — BLE realtime path:** Integrate native encoded audio with bounded queues, stale-frame drops, duplicate suppression, and control priority. Verify production codec interoperability and deterministic congestion/relay tests. Do not equate simulator results with radio capacity.
- **A5 — Complete product integration:** Wire Aware ownership, per-participant routes, reconnect/current-state recovery, and asset availability/resume into both apps. Preserve LAN and test actual production call sites, not only unused transport wrappers.
- **A6 — Software qualification before handoff:** Run the complete simulator/emulator gate, fresh reverse codec interop, cross-language security/wire fixtures, and new transport/topology/route tests. Review diffs and commit focused passing checkpoints. Keep `stable-local-network` unchanged. A passing build alone is not completion.
- **A2 — One user acceptance package:** Supply exact iOS/Android build and commit identities, install steps, one ordered checklist, reusable log capture, and a single results template. The checklist covers both guide directions on LAN, Wi-Fi radio off/Bluetooth on, Aware without an AP, open/locked/wrong-code/edit/unlock, live audio, slides/assets, pin/pointer, route loss/recovery, Bluetooth power recovery, background/locked phones, and endurance. Record unavailable multi-phone scale cases as untested, not passed.

Do not hand back intermediate builds for user testing. Report implementation progress without requesting physical feedback until the candidate and software gates are ready. A consolidated test round collects feedback together; it cannot guarantee that no further hardware-specific fixes will be needed.

Keep `stable-local-network` pointing at `59b0402`. Do not label this remediation checkpoint as qualified Wi-Fi-off operation.

## September 4 room-admission checkpoint

Rooms now start open. Both apps have `Lock Room with Code`, a guide-editable code, discovery lock status, and independent encrypted admission (ADR-052). Existing guests keep their media sessions when the guide locks, edits, or unlocks. Host, simulator/emulator, and individual physical-device room-control checks passed; commands and artifacts are in ExperimentLog.md.

The Android native-audio crash is fixed (ADR-053): Android builds documented codec initialization instead of consuming Apple's opaque cookie, converts actual 48 kHz Opus output to the 16 kHz playback contract, and safely releases failed decoders. Regression fixtures use real production Apple-encoded Opus/AAC packets; direct decoding checks duration, tone frequency, and non-silence, and encrypted-transport replay passes on the Pixel and emulator. The full virtual-device gate passes. This is not a sustained live two-phone listening result: physical endurance and Aware/BLE gates below remain pending.

**Date:** 2026-08-22
**Bluetooth discovery checkpoint (September 4):** The LAN baseline is tagged `stable-local-network` at `59b0402` (annotation: `Stable Local Network`). The first Bluetooth slice adds read-only room metadata to production discovery on both apps (ADR-054). Bluetooth-only rooms show `Audio unavailable` and cannot join; Bluetooth admission/control/audio are not implemented at this checkpoint. Software gates pass, but the Wi-Fi-off two-phone discovery test is pending. Under the September 5 delivery instruction, discovery qualification joins the consolidated physical acceptance round rather than blocking encrypted BLE implementation. Do not move the stable LAN tag to this unqualified radio checkpoint.

**Status:** P0 complete. P3 LAN software hardening through G6 and A1 remediation are implemented. P3 physical acceptance is deferred to the integrated candidate alongside the remaining radio gates. A3–A5 implementation is next. See the 2026-09-02 G1–G6 entries in ExperimentLog.md (executed September 3–4).

## Intent

Preserve the existing local-LAN product as the guaranteed full-capability floor while pursuing operation without external network hardware. Use native cross-platform Wi-Fi Aware as the preferred direct high-bandwidth route and a bounded bitchat-style BLE relay overlay for universal discovery/control and gated degraded live voice. No-AP audio is a capability-dependent mode, not a universal product guarantee.

The tour product remains one guide to many guests with synchronized audio, slides, a shared target pin, and a sightline pointer. Only the target pin may leave a device; participant locations and headings remain local.

## Current evidence

- The local-LAN product path works across the physical iPhone and Pixel, including audio and synchronized visual state.
- The signed iOS Wi-Fi Aware entitlement and Android Aware capability checks pass on the target devices.
- The production floor remains iOS 17, while Wi-Fi Aware requires newer supported hardware and OS versions. Mixed tour groups will therefore depend heavily on BLE when no LAN exists.
- The target Pixel reports a maximum of eight NAN data paths. This is a device-specific limit, but it proves Aware overflow is normal product behavior rather than a theoretical edge case.
- A separate cross-platform AirDrop-like application transferred files successfully on the same device class, which makes native Aware interoperability credible but does not prove this implementation.
- The iOS Aware lab owns the only `NetworkListener` and `NetworkBrowser` that use Wi-Fi Aware. The production Aware lane classes have no application call sites, so the normal iOS app cannot currently establish an Aware session.
- Android-hosted LocalOnlyHotspot/Wi-Fi Direct was unstable in physical use and is removed from the production direction.
- bitchat implements protocol-compatible iOS/Android BLE controlled flooding and 16 kb/s live AAC voice frames. This proves an implementation path exists; it does not prove GetOverHere's group-size, latency, background, or battery requirements.

## Architecture

### Module ownership

| Module | Owns | Planned impact |
|---|---|---|
| Swift `TourSessionCore` | GOH2 wire contract, session state, deterministic CLI | Add transport-neutral realtime frame and relay/dedup fixtures only when required |
| Kotlin `:tour-session-core` | Exact JVM equivalent of the Swift core | Match every Swift wire and state change byte-for-byte |
| iOS app `Core/` | Aware pairing/connection owner, BLE link/relay transport, LAN transport | Complete the missing production Aware bootstrap; add bounded BLE transport behind existing interfaces |
| Android app `core/` | Aware discovery/NDP, BLE link/relay transport, LAN transport | Repair the cross-platform Aware handshake and add the matching BLE transport |
| Platform `Services/` | Audio lifecycle, presentation, assets, guidance, membership | Consume transport interfaces; remain unaware of radio-specific details |
| Platform UI | Tour flow and diagnostic lab | Keep transport diagnostics out of production; expose only join/reconnect/degraded state |
| `scripts/` and platform tests | Cross-language, simulation, build, and device gates | Add topology, stale-audio, route-switch, and physical-test harnesses |

### Dependency direction

```mermaid
graph TD
    IOSUI[iOS UI] --> IOSService[iOS services]
    AndroidUI[Android UI] --> AndroidService[Android services]
    IOSService --> TransportAPI[Transport interfaces]
    AndroidService --> TransportAPI
    TransportAPI --> SessionCore[GOH2 session cores]
    IOSAware[iOS Aware owner] --> TransportAPI
    IOSBLE[iOS BLE overlay] --> TransportAPI
    AndroidAware[Android Aware owner] --> TransportAPI
    AndroidBLE[Android BLE overlay] --> TransportAPI
    LAN[Existing LAN transport] --> TransportAPI
```

Platform frameworks remain in application implementations. The Swift and Kotlin session cores stay platform-neutral and equivalent.

## Selected transport model

| Transport | Product role | Commitment |
|---|---|---|
| Existing local LAN | Audio, control, and assets on every supported OS when a usable LAN exists | Guaranteed full-capability floor; maintained and tested as a first-class route |
| Native Wi-Fi Aware | Preferred direct audio, control, and asset route without an access point | Capability-, interoperability-, and data-path-limit gated |
| BLE controlled relay overlay | Universal discovery, authentication bootstrap, control, membership, and degraded compressed voice | Control is required; voice ships only if P5 passes |

The app may run BLE and IP transports concurrently. Per-participant preference is healthy Aware, then LAN, then BLE. Stable session, participant, stream, and sequence identifiers suppress duplicates and allow a guest to change routes without becoming a second listener.

Aware and BLE voice have independent planning risks of 35% and 45%. A rough compounded model leaves a 15–25% chance that neither no-AP audio route is shippable. In that outcome BLE remains control-only and a local LAN remains required for tour audio. Product claims and UI must state that directly.

The plan does not bridge Apple peer-to-peer Wi-Fi to Android Wi-Fi Direct, elect an Android hotspot host, or depend on a portable router.

## Scope

### In scope

- Cross-platform Aware discovery, pairing, NDP establishment, and an initial application connection.
- iOS production ownership of Aware listeners, browsers, accepted connections, and reconnects.
- Encoded, sequenced, expiring realtime audio suitable for Aware and BLE.
- BLE devices operating as central and peripheral, with bounded forwarding, split horizon, TTL, deduplication, jitter, rate limits, and successor recovery.
- BLE delivery of authoritative control snapshots and degraded live audio.
- Per-participant route selection across Aware, LAN, and BLE without duplicate state or audio.
- End-to-end application payload encryption using per-tour keys and per-packet nonces, independent of link encryption.
- Existing slides, shared-screen state, target pin, pointer, listener count, reconnect, and privacy behavior across the selected route.
- Deterministic CLI topology simulation and focused commits at every passed gate.

### Out of scope

- Android LocalOnlyHotspot or Wi-Fi Direct as a production dependency.
- Bridging incompatible Apple and Android proprietary peer-to-peer Wi-Fi networks.
- General-purpose ad-hoc routing, Internet relay, Nostr, store-and-forward chat, or courier delivery.
- Guest microphone transmission or multiple guides.
- Forwarding participant location or heading data.
- Shipping an unbounded BLE file flood. BLE asset transfer remains experimental and subordinate to live audio.

## Execution phases and gates

### P0 — Baseline and traceability

**Result:** P0 is complete. Harness and baseline verifier passed on 2026-08-23. The harness correctly rejected a missing Android device and a locked iPhone before starting capture. The first complete two-device artifact belongs to the deferred P3 physical gate, not P0.

- Commit this planning/ADR/lesson update as one documentation checkpoint after approval.
- Preserve the working LAN path as the rollback baseline.
- Add a reusable physical-test script that captures app events and platform radio logs without inspecting private frameworks or binaries.

**Gate P0:** clean focused commit; existing `scripts/verify_tour_session.sh` remains green.

### P3 — Harden transport-neutral payloads and replace raw PCM/TCP audio

**Progress:** LAN software integration landed August 27 and G1–G6 hardening landed September 3–4. Realtime, control, and asset lanes now use encrypted GOH2 v4 with PBKDF2-stretched tour credentials; audio negotiates native Opus then AAC-LC, accumulates PCM16 into codec frames, applies sequence/expiry metadata, compensates for cross-device clock offset, and decodes through a bounded, clock-driven jitter buffer. The local gate passes Swift/Kotlin wire fixtures, LAN loopbacks, the source audit, 74 Android JVM tests, and 82 iOS unit/integration tests. Hosted core parity passed on September 4 ([run 33930529033](https://github.com/aessam/GetOverHere/actions/runs/33930529033)). Use `scripts/verify_virtual_devices.sh` to include the full iOS UI and Android emulator suites; hardware-only capture/routing tests explicitly skip. Physical codec, RF, latency, background, thermal, and battery gates remain pending. Actual byte-identical delivery of one sealed frame across concurrent LAN/Aware/BLE routes remains a P6 integration gate; unqualified Aware audio fails closed and retired Multipeer code has been deleted.

- Lock the frame rules before fixtures: one logical frame is encrypted exactly once at creation, then the byte-identical sealed frame is routed one or many times. Socket writers never encrypt or choose nonces.
- Make the encrypted protocol a hard version break. A legacy or unsupported major produces an explicit version-mismatch event and user state rather than a generic connection/radio failure.
- Probe installed native encoders and decoders first. Query Apple Audio Format Services on the physical iPhone and Android `MediaCodecList` on the physical Pixel before a codec identifier enters the wire fixture; do not add `libopus` during this spike.
- Select the codec from that evidence: native Opus with 20 ms frames is preferred; native AAC-LC 16 kHz/16 kb/s is the fallback if the supported-device native Opus gate fails.
- Define one cross-platform encoded realtime frame with stream ID, sequence, capture timestamp, codec configuration, expiry, and sealed payload.
- Add route-independent authenticated encryption for realtime, control, and asset payloads; remove every plaintext application payload path from the working LAN product.
- Use datagrams where the transport supports them, a bounded jitter buffer, packet-loss concealment, and stale-frame dropping.
- Preserve receiver/headset default output and the background audio lifecycle.

**Gate P3:** native codec capability and encode/decode probes are recorded for both physical target devices; exact Swift/Kotlin frame, byte-identical multi-route ciphertext, tamper/replay, and version-rejection fixtures pass; the source/wire verifier finds no plaintext application payload path; 30-minute physical LAN audio passes in both guide directions; mouth-to-ear latency, loss, jitter depth, thermal state, and battery delta are recorded; an injected loss burst never creates an unbounded playback backlog.

### P1 — Reproduce and repair the isolated Wi-Fi Aware lab

- Run iPhone publisher → Android subscriber and Android publisher → iPhone subscriber.
- Test with infrastructure Wi-Fi disconnected, connected to the same LAN, and only one device connected to infrastructure Wi-Fi.
- Record the first failing stage: discovery, PIN bootstrapping, pairing persistence, NDP, socket readiness, or UDP exchange.
- Compare only public API usage and observable behavior with the working AirDrop-like application.
- Keep the lab isolated until both directions pass.
- Timebox the lab to four focused physical-debug sessions or two engineering days, whichever comes first. Each session must isolate one failing stage and end with recorded evidence.

**Gate P1:** both directions establish a direct Aware data path and run the deterministic 20 ms probe for 15 minutes with zero malformed frames, measured loss/RTT, and a successful disconnect/reconnect. If the gate has not passed at the stop-loss, record the exact blocker, park Aware until new vendor/OS evidence or a concrete code hypothesis exists, and continue with LAN plus P4/P5.

### P2 — Complete the production Aware connection owner

- Add the missing iOS production listener/browser/pairing owner.
- Reconcile it with Android's existing production Aware session owner.
- Establish one initial authenticated connection, then open realtime, control, and asset lanes from that established Aware relationship.
- Keep iOS 17 support for LAN/BLE; Aware remains runtime-capability gated.

**Gate P2:** iOS guide ↔ Android guest works in both guide directions without a LAN, authenticates all three GOH2 lanes, counts one stable participant, transfers one slide, and restores state after reconnect.

### P4 — BLE control overlay

- Implement ADR-038 first: create one ephemeral P-256 guide signing key per tour, pin its verification key through QR or a prior direct authenticated guide connection, and sign each immutable sealed guide frame once before fan-out.
- Verify the guide signature before decrypting or applying any relayed frame. Reject unsigned frames, changed ciphertext/signatures, and keys that do not match the pinned guide key.
- Do not relay guest-authored application frames in P4. BLE topology and link-admission messages remain point-to-point; any later guest-frame relay requires guide-issued participant certificates.
- Reuse the validated bitchat concepts, not its product or entire codebase: central+peripheral roles, TTL, message deduplication, split horizon, deterministic fan-out, relay jitter, and bounded topology announcements.
- Keep one authoritative guide. Use epochs, leases, and an ordered successor set instead of full Raft.
- Start with a maximum of six direct central links as an experimental policy, not a platform guarantee.
- Forward only authenticated current-session traffic.

**Gate P4:** byte-exact Swift/Kotlin fixtures prove one signed sealed frame verifies unchanged across direct and relayed delivery, and reject unsigned, wrong-key, modified-ciphertext, and modified-signature cases. Deterministic simulation then passes line, star, overlapping-star, partition, duplicate-flood, relay/successor loss, and reconnect scenarios at 1/5/10/20/50 logical nodes; physical 2/5/10-device discovery and control convergence are measured foreground and locked.

### P5 — BLE live-voice fallback

- Send encoded live frames at realtime priority through the BLE overlay.
- Never retransmit expired audio, persist it, or allow it behind asset traffic.
- Bound relay depth initially to two hops and drop frames that cannot meet the playback deadline.
- Keep presentation snapshots on the reliable control path.

**Gate P5:** after the initial one-guide/two-direct/one-relayed proof, physical voice gates progress through 5 and 10 mixed iOS/Android devices. One-hop and two-hop mouth-to-ear latency, loss, queue depth, thermal state, battery use, and locked/pocketed behavior are recorded. There is no queue growth or duplicate playback. If this gate fails, BLE remains control-only.

### P6 — Hybrid route selection

- Prefer a healthy authenticated Aware route, then LAN, then BLE.
- Select routes per participant; do not switch an entire tour because one guest lacks Aware.
- Never attempt more Aware peers than current runtime resources permit. On the target Pixel's reported eight-path limit, guest #9 tries authenticated LAN, then BLE voice if P5 passed, then explicit BLE control-only mode with audio unavailable.
- Do not evict an existing Aware guest to admit an overflow guest. A control-only guest is not counted as receiving audio; the guide sees separate connected and audio-ready counts without radio diagnostics.
- Send authoritative snapshots after every route change.
- Deduplicate overlapping delivery by session/stream/sequence before playback or state application.

**Gate P6:** guests with different available transports participate in the same tour; capacity-plus-one overflow and route loss/recovery produce no duplicate participant, audio, slide, pin, or pointer state. A 60-minute physical run keeps Aware, BLE central, BLE peripheral, LAN, audio encode, and active playback/control traffic enabled concurrently on the guide while recording coexistence loss, thermal state, and battery delta.

### P7 — Assets and degraded behavior

- Use Aware/LAN for full slide and map assets.
- Measure low-priority BLE slide transfer only after P5 passes; pause or throttle it whenever audio is active or backpressured.
- When an uncached asset cannot arrive over the current route, show an explicit pending/degraded state while audio and control continue.

**Gate P7:** cached slides always follow control state over BLE; an uncached slide either transfers within the measured bound without harming audio or produces the explicit degraded state. PMTiles remains an Aware/LAN or preloaded asset.

### P8 — Scale and product acceptance

- Mixed-route tour gates: 8, 16, 32, then 50 guests. Direct Aware count never exceeds the guide's runtime resources; test capacity-minus-one, capacity, and capacity-plus-one before larger mixed-route gates.
- BLE physical topology gates: 2, 5, then 10 devices, with larger counts covered first by deterministic simulation.
- Exercise both guide platforms, mixed infrastructure-Wi-Fi states, lock/background, leave/rejoin, session restart, slides, pin, pointer, asset transfer, interference, and churn.
- Name and run the common AP-less field case: mixed iOS 17–current and Android guests, at least half locked and carried in pockets, with unsupported/exhausted Aware peers using BLE.

**Gate P8:** every product requirement has physical evidence in `ExperimentLog.md`; no privacy payload regression; no capacity claim exceeds the largest passing physical gate.

## Execution flow

```mermaid
graph TD
    P0[P0: baseline + focused commit] --> P3[P3: encrypted encoded realtime]
    P3 --> P4[P4: BLE control overlay + software gates]
    P4 --> P5[P5: BLE voice + software gates]
    P5 --> P2[P1/P2: Aware lab readiness + production owner]
    P2 --> P6[P6: hybrid per-participant routing]
    P6 --> P7[P7: assets + degraded behavior]
    P7 --> V[Complete simulator/emulator qualification + committed candidate]
    V --> P8[One physical acceptance package: LAN, BLE, Aware, hybrid]
    P8 --> G{Physical evidence meets route gates?}
    G -->|yes| S[Enable only qualified product capabilities]
    G -->|no| F[Collect feedback together; fix or restrict affected capability]
```

## Cross-cutting action

**A8 — Traceability applies to every phase.** Before risky work, preserve the last passing state. After each gate: run the relevant verifier, append exact commands/results to `ExperimentLog.md`, update `ADR.md` or `LessonsLearned.md` when the conclusion changes, review the diff, and create one focused commit before starting the next phase. Never bundle two unproven radio changes into one commit.

## Definition of done

- The guaranteed floor is a first-class mixed iOS/Android LAN tour with full audio, control, and assets and no Internet dependency.
- Supported Aware devices can run the full tour without an external access point after P1/P2 pass.
- Guests without a usable Aware path still discover, authenticate, and receive current control state; they receive no-AP live audio only if P5 passes.
- If both Aware and BLE voice gates fail for a participant, the app explicitly requires a usable LAN for audio. No product claim promises AP-less audio to every supported phone.
- Audio, slides, shared map target, pointer, membership, background behavior, and reconnect pass in both guide directions.
- Every payload is authenticated and encrypted end-to-end at the application layer.
- Participant location and heading never enter a transport payload.
- The supported group size equals the largest passing physical gate, not a theoretical number.

## Risks and rollback

| Risk | Estimated likelihood | Early detection | Prevention | Rollback |
|---|---:|---|---|---|
| Android↔iOS Aware pairing/NDP remains unstable | 35% | P1 cannot pass both roles repeatedly | Isolated lab, public APIs only, exact stage logs | Keep production LAN untouched; continue BLE control/voice work independently |
| Continuous BLE voice congests relay links | 45% | Queue depth, loss, or latency grows at one relay | Compressed frames, deadline drops, two-hop cap, no retransmission | BLE returns to control-only |
| Locked/background relay disappears | 40% | P4/P5 locked-device topology partitions | Platform audio lifecycle, successor set, route snapshots | Require direct BLE/Aware audio; relays become opportunistic |
| Aware runtime capacity is exhausted | High in groups above a device's NDP limit | Available path count reaches zero; capacity-plus-one gate | Per-participant admission and explicit overflow policy | LAN, then gated BLE voice, then control-only |
| Concurrent guide radios degrade one another or drain the battery | 35% | P6 coexistence loss, thermal state, or battery delta exceeds the route-specific baseline | Run the complete radio mix together; disable unused routes per participant | Keep LAN floor; reduce concurrent optional radios |
| Concurrent Aware/LAN/BLE duplicates membership or playback | 25% | Duplicate participant IDs or sequence playback in P6 | One route lease per participant plus pre-delivery dedup | Disable automatic switching; require explicit reconnect |
| Radio work outruns traceability again | 20% | Multiple transport changes appear before a passing gate/commit | A8 checkpoint rule and focused commits | Return to the last passing commit and rerun its gate |

Probabilities are planning estimates, not measured field rates. Treating the 35% Aware and 45% BLE-voice estimates as roughly independent gives a 15.75% dual-failure case; shared RF, background, and device factors justify planning for a 15–25% range. In that case the LAN floor remains the only full audio route.

## Recommended execution mode

Integrated implementation, then consolidated physical acceptance. Keep software gates and focused commits between phases; do not require user device feedback between coding milestones. Prepare the full candidate and the A2 acceptance package described above before requesting a test round. Physical failures determine fixes and shipping capability limits, not whether unrelated implementation may proceed. Keep the P1 physical investigation timebox and all security/privacy boundaries.
