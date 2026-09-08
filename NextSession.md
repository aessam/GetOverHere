# GetOverHere — Next Session

## Read this first

Authoritative handoff after Android Aware benchmark commit `7dca55f` and the user's two external research reports. Both reports label their research date **8 September 2026**; that is author attribution, not a new local experiment date. Latest locally recorded physical/software runs remain September 7. This handoff update is documentation-only: no new radio test, pairing integration, UDP implementation or guide-key integration occurred while archiving research.

**The product is not finished.** Direct Android BLE/Aware fixtures and the two-phone Aware throughput benchmark pass. Thirty-person capacity, mixed-platform Aware, live acoustic/locked/endurance qualification, production guide-key pinning, authenticated relay and complete hybrid scheduling remain unfinished. The user wants all coherent coding/software gates before one consolidated manual acceptance package, not repeated intermediate builds for feedback.

### Repository and checkpoint

- Workspace: `/Users/aessam/tmp/ios-macos-apps/GetOverHere`.
- Branch: `fix/deep-dive-2026-09-02`.
- Latest verified implementation: `7dca55fe482ecf0d51aa74122118389ad84a6446` (`Benchmark Android Aware and avoid listener port collisions`). A later documentation commit does not imply a newly tested app binary.
- Stable annotated tag: `stable-local-network` → `59b0402c91cfabb3eb839800b2b8521be90854e0`, annotation `Stable Local Network`. **Do not move it.** No push without a sharing request; no co-author in commits.
- All previously launched benchmark and qualification jobs finished. No paid resources were started. Dedicated simulator/emulator were retained; check actual availability before use, without restarting shared services.
- [Historical checkpoints and original P0–P8 plan](NextSession-History.md) preserve all older phases, failures and acceptance gates. Their “discovery only”, “no production Aware owner”, unavailable-Android, and mandatory-code statements are not current state.
- [ADR.md](ADR.md), [LessonsLearned.md](LessonsLearned.md), and [ExperimentLog.md](ExperimentLog.md) retain decision, debugging and exact-command evidence.

## Product and boundaries

One walking guide speaks to approximately **30 listeners**, shares slides/images, a map target and a sightline pointer. Guest locations/headings remain local. This is not a multi-speaker conference. Thirty is the target, not a measured supported group size.

Rooms start open. Both apps expose **Lock Room with Code** and a guide-editable code. No mandatory tour code, QR, cloud account, Internet service or external router for the intended router-free experience. Native system device-pairing consent is distinct from optional application room locking.

| Network condition | Current direction | Evidence boundary |
| --- | --- | --- |
| Shared LAN, no Internet | Preserve existing LAN audio/control/assets | No 30-device qualification or newly implemented multicast follows from research |
| No AP, Wi-Fi and Bluetooth enabled | Capability-gated Aware plus BLE, pursuing public mixed-platform interoperability | Android direct Aware fixture passes; speed run retained AP association but used explicit Aware sockets |
| Wi-Fi radio disabled, Bluetooth enabled | BLE direct lanes and separately qualified fallback voice | Two-Android functional fixtures pass; mixed/locked/group acoustic behavior unproven |

True radio groupcast, IP multicast, discovery advertising, replicated peer unicast and application relaying are different mechanisms. Research found no usable ordinary-app one-transmission-to-30-mixed-phones router-free API; this is an API finding, not proof that every standard or chipset lacks group addressing.

**Keep router-free as the objective and LAN as fallback.** A mandatory portable AP, hotspot/Wi-Fi Direct dependency, public release cap, mandatory human verification, individual member revocation, or lowered OS baseline is not approved merely because a report recommends it. No private APIs, root/jailbreak, unrelated cleanup or silent plaintext fallback.

## Completed implementation and qualification

| ID | Completed work | Evidence and remaining limit |
| --- | --- | --- |
| C1 | LAN software hardening: encrypted GOH2 v4 realtime/control/assets, native encoded audio, sequence/expiry/replay policies, jitter buffering, presentation/focus/target/pointer state, content validation/recovery | Historical G1–G6/P3 in ExperimentLog; reuse existing features/tests. Group/endurance qualification remains open |
| C2 | Open-by-default admission, optional lock/editable code, discovery lock state; admitted guests keep sessions on lock/edit/unlock | ADR-052, September 4 history; lock changes are not member revocation |
| C3 | Apple→Android codec initialization/crash fix; reverse Android→iOS real codec fixtures; fixed leading-zero ECDH and main-gate admission parity | `59b0402`, `492572e`, ADR-053/055; fixtures are not acoustic qualification |
| C4 | BLE/LAN discovery merge, explicit feature-boundary permissions, role-specific bounded scan/advertise lifecycle and error recovery | `7a41610`, `492572e`, ADR-054/055; original discovery-only capability superseded by C5 |
| C5 | Direct BLE L2CAP and native Aware owners feed admission/realtime/control/assets through GOD1 fixed-lane adapters; capability-aware joining, cleanup and endpoint re-resolution | `8c73fa9`, ADR-056. Android PIN-derived SK-128 and Apple system pairing are not yet an interoperable mixed-Aware profile |
| C6 | Native realtime bounds: eight queued frames, 150 ms queued-audio expiry, one-second write/ACK deadline, four-frame native ACK window | ADR-056; Android BLE both guide directions with Wi-Fi disabled before joining. No relay/acoustic/group claim |
| C7 | Fatal Aware owner teardown/retry, stale-generation isolation, per-peer failure separation; iOS error/context surfaced without guessing `-11992` | `9f47662`, simulator lifecycle regressions; exact iPhone cause unresolved |
| C8 | Swift/Kotlin guide-side admission drain after local EOF, capped at five seconds awaiting peer completion | `c1c18d0`, deterministic red/green/timeout tests and physical BLE both roles; no wire change |
| C9 | Canonical P-256 low-S GOS1 primitives over immutable GOH2 ciphertext; externally supplied guide/session pin | `477f244`, ADR-057, native provider parity. **Core only:** admission key delivery, lifecycle pinning and production signing integration not done |
| C10 | Native two-Android Aware benchmark with exact payload/sequence/counter verification, foreground/keyguard monitoring, setup/RTT/thermal metrics, bounded runner/APK manifests | `7dca55f`, all 18 measured trials pass; synthetic transport, not full-tour encryption/codec throughput |
| C11 | Confirmed fixed-port collision repaired through dynamic listener allocation/advertisement; native stage logs; benchmark completion-owner lifetime fixed | `7dca55f`, occupied-port/completion regressions red then green. Not every older discovery failure is explained |
| C12 | Full frozen software gate and post-fix Android Aware tour fixtures in both guide orientations | Logs below; no new iPhone, group, acoustic, deliberate lock or endurance qualification |
| C13 | Both research reports archived with their references; corrections and ordered follow-up recorded | This documentation checkpoint, not new app implementation |

### Final benchmark, not the preliminary pilots

Three 10-second measured trials per mode, three modes, both guide roles. Every received 65,536-byte block, sequence and counterpart byte total checked; warm-up excluded. Receiver goodput includes receive/drain time.

| Guide | Median guide→guest | Median guest→guide | Median duplex guide→guest | Median duplex guest→guide |
| --- | ---: | ---: | ---: | ---: |
| Pixel 11 Pro | 300.05 Mbps | 292.46 Mbps | 180.56 Mbps | 181.44 Mbps |
| Pixel 7 | 307.41 Mbps | 299.36 Mbps | 185.69 Mbps | 181.37 Mbps |

Highest sustained 10-second one-way trial: **326.61 Mbps**. Idle 100-sample RTT p50/p95: **14.64/155.02 ms** forward and **17.47/171.04 ms** reverse. Loaded duplex per-trial p95 reached **234.47 ms**. Guest-local four-channel setup: **2.14/3.99 seconds**. Native thermal status 0 at recorded samples is not battery/endurance proof.

Evidence: `/tmp/GetOverHere-aware-benchmark-final.log`; `/tmp/GetOverHereAwareBenchmark.po2lx70k/` contains `manifest.json`, `results.json`, forward/reverse guide/guest output, emulator regressions and scoped app logs. Durable results, hashes, method and failed attempts are in the **2026-09-07 — Two-phone Android Aware throughput benchmark** section of [ExperimentLog.md](ExperimentLog.md). Temporary files may disappear; reading logs is not a new rerun.

Measured APKs came from `c1c18d0` plus changes subsequently committed in `7dca55f`. App SHA-256: `783139bc2b5231b1a4d310e4619070eec6a86cc328d31b92b22a6e8a772bfe0a`; test APK SHA-256: `cc34a08e989d75f709f05ef51458abaaab747de60f29a02f8632a311bc744dfd`.

Wi-Fi stayed enabled, phones were USB-connected and foreground, AP association was not removed. Payload used explicit Aware sockets, not USB/Internet/LAN fallback. Distance/RF conditions were not measured. Do not use the short pilot's higher peak, equate RTT/2 with measured one-way delay, or infer 30-peer scheduling from bulk throughput.

### Passing gates and failures retained

- Full host/iOS unit/UI/Android emulator/native-provider gate: `/tmp/GetOverHere-aware-benchmark-virtual-final.log`, ending `Virtual-device verification passed; physical audio and radio gates remain separate`, including 100 native cross-provider signature checks.
- Actual Aware tour: `/tmp/GetOverHere-aware-dynamic-tour-forward.log` and `/tmp/GetOverHere-aware-dynamic-tour-reverse.log`; both complete harnesses passed admission/control/exact assets/non-silent native-decoded audio. These are not microphone→speaker tests; the legacy tour fixture does not enforce continuous foreground/keyguard state like the benchmark.
- Disabled-Wi-Fi BLE: `/tmp/GetOverHere-drain-off-forward.log` and `/tmp/GetOverHere-drain-off-reverse.log`; both original Wi-Fi settings restored/read back enabled. A prior guide was observed asleep behind keyguard; that is not controlled lock-transition qualification.
- Retain startup failure `/tmp/GetOverHere-aware-benchmark-pilot.log`, occupied-port red/green `/tmp/GetOverHere-aware-port-red.log` and `/tmp/GetOverHere-aware-port-green.log`, failed long completion `/tmp/GetOverHere-aware-benchmark-measured.log`, and completion regression `/tmp/GetOverHere-aware-bench-end-red.log`. Earlier `/tmp/GetOverHere-aware-benchmark-virtual.log` caught the deliberately red completion test; it is not final qualification.
- Older reverse-Aware discovery intermittency and iPhone `-11992` remain separate failures; later passing runs do not erase them.

## Research archive and adjudication

- **RES-C — [Claude report: full supplied text and source list](Research-Claude-2026-09-08.md).** Section 12 retains its references. Do not adopt its categorical lock/interoperability/scale conclusions.
- **RES-G — [ChatGPT report: full supplied text and source list](Research-ChatGPT-2026-09-08.md).** Stronger experimental starting point. Portable-AP primary mode, rekey/removal, PAKE library/profile and LAN multicast rewrite are proposals, not automatically authorized changes.
- [CrossPlatformP2PResearchPrompt.md](CrossPlatformP2PResearchPrompt.md) is the earlier research brief, not necessarily the exact latest prompt used for these reports. The user supplied both full reports in the conversation; their entire research was not independently rerun locally.

Report-local codes collide. Prefix them with RES-C or RES-G. **F1–F6 and A1–A4 below retain the codes from the latest conversation synthesis**, not the older checkpoints or report-local numbering.

### F1–F6 — Corrections governing follow-up

- **F1 — Lock is not suspension.** Claude's blanket claim that iPhone Aware audio must stop on lock is wrong. Apple allows Aware while the app executes in the background, closes connections on suspension, and separately describes idle cleanup. Genuine active background audio is a path to qualify; fresh locked discovery, idle pauses and relay-only execution are separate. No silent audio to manufacture background execution. [Apple DTS 787570](https://developer.apple.com/forums/thread/787570).
- **F2 — Offloaded pairing is a candidate, not confirmed on our phones.** Android documents `setFrameworkOffloadedPairingEnabled` as added in **version 37.2**, system-mediated pairing, override of app pairing configuration and a recommended setup timeout of at least 30 seconds. Major API 37 does not prove this addition or hardware role support. Check SDK/runtime and documented bootstrapping capabilities before an isolated probe. [PublishConfig.Builder](https://developer.android.com/reference/android/net/wifi/aware/PublishConfig.Builder#setFrameworkOffloadedPairingEnabled(boolean)), [SubscribeConfig.Builder](https://developer.android.com/reference/android/net/wifi/aware/SubscribeConfig.Builder), [Characteristics](https://developer.android.com/reference/android/net/wifi/aware/Characteristics).
- **F3 — Latency cause is unknown.** [NearbySocketBridge.kt](Android/app/src/main/java/com/aessam/comeoverhere/core/NearbySocketBridge.kt) already sets `tcpNoDelay = true` in `NearbyTCPConnection`. Audit all legs and compare direct TCP, direct UDP and current adaptation before blaming Nagle. Apple exposes realtime performance mode, voice traffic class and performance reports; inspect existing settings and measure. [WWDC25 optimization guidance](https://developer.apple.com/videos/play/wwdc2025/228/).
- **F4 — No security shortcuts.** Discovery-advertised/self-signed keys do not establish trusted human guide identity. Admission binding and session pinning provide continuity within the stated first-contact model. Signing every Nth frame leaves a gap unless a reviewed construction authenticates all others. Intended producer work is encrypt/sign once then copy immutable bytes, not 30 signing operations per frame. ADR-038/057 and [SignedGuideFrame.swift](Packages/TourSessionCore/Sources/TourSessionCore/SignedGuideFrame.swift) define the prerequisite; app integration remains pending.
- **F5 — Neither report qualifies 30 or authorizes routers.** Claude's initial mixed-router-free “yes” contradicts its later “not supported”; separated platform islands do not deliver one guide to a mixed group. ChatGPT's AP design still needs qualification and is not the selected product direction. Mixed Aware is unproven, not universally proved impossible. Shared-LAN multicast is not an already completed replacement for our lanes.
- **F6 — Wire/software capacity also matters.** The ~79 kb/s/listener estimates omit some existing protocol metadata. Measure serialized GOH2/GOS1, native framing/ACK and per-peer costs. [NearbySocketBridge.kt](Android/app/src/main/java/com/aessam/comeoverhere/core/NearbySocketBridge.kt) defaults to **32 concurrent connections**, not guests, with multiple lanes per session. Audit all admission/link/queue caps before choosing group capacity; do not arbitrarily raise a constant.

Other cautions: keep iOS 26.4 guards until actual API requirements are checked and preserve the iOS 17 baseline. Device PIN security is distinct from guide-editable room code (RES-G conflates them once). Historical eight-NDP diagnostic is a per-device observation to reread, not a universal limit. PAKE does not remove online guessing or authenticate human identity. Both reports' latency thresholds are proposed, not accepted tour SLAs. Unchecked API/hardware specifics remain research leads.

## Planned work — execution order and gates

Nothing below is completed by saving reports. Safe security/hybrid coding need not wait for an unavailable iPhone; physical gates control claims. Preserve focused verified commits. Begin with tiny harness smoke, not the Cartesian product of every proposed experiment.

### A1 — Android resource and small-packet latency harness

1. Extend the existing test-only benchmark boundary. Capture build/full SDK support, Aware availability, maximum/current NDPs/interfaces and network-bound provenance before/after one peer and multiple sockets. Keep diagnostics scoped; never log PINs, keys, payloads or unrelated traffic.
2. Map sockets to NDPs and audit every app cap: native connections, pending admissions, lanes per participant, queues. Resources are observations, not reservations. Two phones cannot prove 30-peer capacity.
3. Add deterministic probes at actual serialized audio size/cadence. Compare current loopback adaptation, direct TCP with recorded options, and a test-only native UDP path. Record loss/late delivery, jitter, queue age and p50/p95/p99 RTT; do not use RTT/2 as measured one-way delay.
4. Emulator protocol smoke, bounded physical pilots both roles, then randomized controlled comparisons. Start idle versus paced assets before saturation. AP-unassociated/radio changes require explicitly scoped/restorable setup. No hidden automatic retries.
5. Instrument per-stage timestamps and reusable result manifests. Decide production UDP/native-lane changes from evidence, retaining the known-good adapter until admission, crypto, expiry, replay, reconnect and lane tests pass. Do not blindly carry reliable-stream ACK semantics into expiring UDP.

**Gate:** exact payload/sequence tests, native route proof, resource accounting and reproducible latency distributions leading to a transport decision. Maps to RES-G E1/E2 and RES-C E2/E3.

### A2 — Public pairing probe and iPhone failure isolation

1. Check installed SDK/runtime for the documented 37.2 addition, pairing and bootstrapping roles. No private API/reflection bypass. Keep Android↔Android PIN-secured operation as a separate compatibility profile.
2. Where supported, add an isolated framework-offloaded-pairing probe using matching Apple declarations/public contracts. Do not rename production `_goh-tour._tcp` to a report's `_udp` example without changing the matching transport contract.
3. Record discovery, consent/bootstrap, pairing persistence, NDP, endpoint/socket readiness, real byte exchange and reconnect separately in both roles. Verify additional-port API availability before lowering iOS guards.
4. Once an iPhone is available/authorized, capture the exact operation returning `NWError.wifiAware(-11992)` and scoped diagnostics. Entitlements are present; meaning/cause is unknown. Full sysdiagnose/bugreports can include unrelated private data: obtain only as needed within authorization.
5. Preserve P1's four focused physical-debug sessions/two-engineering-day stop-loss unless changed by the user. New documented capability is a concrete hypothesis; absent hardware is not a reason for blind retries. A failed route does not block unrelated BLE/security coding.

**Gate:** real direct bytes and reconnect both orientations without LAN fallback, then repeated pairing and production lanes. API existence/pairing callbacks alone fail the gate. Maps to RES-G E3/RES-C E4. Two-Android authorization is not iPhone authorization.

### A3 — Admission-bound guide key and immutable production frames

1. Define a versioned direct-admission reply/transcript delivering the ephemeral guide verification key, bound to session/guide IDs, roles, request and key confirmation. Keep rooms open/code-free by default, state first-contact trust limits, and reject key substitution during session/reconnect.
2. Integrate sign-once/verify-before-open across every authoritative realtime/control/asset producer and receiver, not only core fixtures. Reuse identical signed ciphertext across routes; socket writers never allocate nonces. Keep replay/expiry/version rejection.
3. Audit [HybridSessionTransports.swift](iOS/GetOverHere/Core/HybridSessionTransports.swift) and Android equivalents: route fan-out can enter separate sealing owners. Consolidate at the logical producer rather than wrap independently sealed copies. Update native GOH2-kind inspectors/frame ceilings for the outer GOS1 header and 72-byte wrapper/signature overhead.
4. Add cross-language/native-provider tests for pins, guide/session IDs, tamper, truncation, replay, version, reconnect, overlapping route bytes, evil-twin limitations and bounded expensive work. Crypto does not prevent relay drop/delay.
5. Keep ADR-052 short-code active malicious-guide/offline attack and session-wide revocation limits explicit. PAKE library/profile, optional SAS/QR, individual rekey/removal and expanded epochs are **pending design/scope decisions**, not approved merely by the reports. No custom crypto or raw-code comparison replacement.

**Gate:** production direct/overlapping delivery preserves identical signed bytes and only session-pinned guide authority; malicious admitted guests cannot forge guide frames; open/lock/edit/unlock and LAN remain green. Use ADR-038/057, both security sections and RES-G E9 with F4 corrections.

### A4 — Direct audio qualification, bounded relay and hybrid completion

1. Measure real capture→codec→AEAD/sign→native link→decode→playback on both Android roles, then mixed BLE/Aware where available. Use synchronized/external acoustic measurement for mouth-to-ear/playback skew. Generated decoded tones prove codec/transport only; distinguish headphones/receiver from group loudspeakers.
2. Test active capture/playback after lock separately from fresh locked discovery, idle pauses, relay-only backgrounding, interruptions/headset changes and power modes. Audit genuine iOS audio/background modes and Android role-correct foreground services. No fake silent audio.
3. Select bounded relay topology from A1 resource evidence, after A3 key/bootstrap integration. Implement central/peripheral and publish/subscribe coexistence, fixed fan-out/depth, session leases, TTL, split horizon, dedup, expiry, rate limits and successor recovery. No unsigned relay, arbitrary flooding, guest-authored authoritative traffic or stored speech.
4. Test deterministic line/star/overlapping-star/partition/relay-loss simulations before physical claims. Relay upstream/downstream both consume resources; a tree relieves guide fan-out but not total transmissions. Two phones cannot validate a five-by-five tree.
5. Complete per-participant routes and explicit capacity overflow, connected versus audio-ready counts, pin/session continuity, snapshots and dedup before playback/state. Never evict healthy guests for overflow. Current discovery preference is LAN→Aware→BLE; target route preference/failover needs explicit policy/tests, not historical prose treated as implemented behavior.
6. Reuse existing asset hashes/manifests, transfer bounds, resume and state snapshots. Add shared scheduling for audio/control versus current/next slides and bulk assets; test uncached/degraded states, backpressure and late joins. Do not rebuild tested caches.
7. Progress physical scale through capacity-minus-one/capacity/capacity-plus-one, then larger available groups toward 30 after direct/software gates. BLE Wi-Fi-disabled qualification is separate and restores settings. Run 60–90-minute walking/lock/coexistence cases with battery/thermal/range evidence, selecting actual acceptance thresholds before declaring passes.

**Gate:** no authority escalation, duplicate playback/state, stale backlog, hidden route failures or invented capacity; supported size equals largest passing physical group. Maps to RES-G E4/E5/E6/E8/E9, RES-C E1/E5/E6 and historical P4–P8. RES-G E7 portable-AP qualification is a fallback proposal, not authority to buy equipment or mandate a router.

### Integrated delivery after coding

- Run host/core/cross-language/security/route/topology gates and full simulator/emulator suites against reachable production paths. Commit focused verified milestones, not two unproven radio changes together.
- Prepare one integrated iOS/Android candidate with exact commit/APK/build identities, install/log-capture instructions, one ordered acceptance checklist and one feedback template.
- Checklist: both guides; LAN without Internet; no-AP Aware; Wi-Fi-disabled BLE; open/lock/wrong-code/edit/unlock; live megaphone; slides/assets/pin/pointer; late join; route/radio recovery; lock/background/interruptions; endurance; measured capacity and explicit untested cases.
- Unavailable iPhone/group gates remain untested, not passed. One feedback round cannot guarantee no further hardware fixes.

## Resume environment and commands

Last authorized pair: Pixel 11 Pro `66180DLKX006ND`, Pixel 7 `2A111FDH2007A1`, API 37 at benchmark time. User said both unlocked without passcode. Check availability before running; only wake/dismiss non-secure keyguard, never change credentials. iPhone unavailable/out of scope until reauthorized. Emulator `emulator-5554`, API 36 at last run.

ADB `/Users/aessam/Library/Android/sdk/platform-tools/adb`; Java `/Applications/Android Studio.app/Contents/jbr/Contents/Home`; Xcode `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer`. Dedicated simulator `B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98` (`GOH-Signature-20260907`, iPhone 17 Pro/iOS 26.4.1 at last run). DerivedData `/tmp/GetOverHereSignatureIOS`.

```bash
# Read-only preflight; no install or radio mutation.
git status --short
git log -8 --oneline
python3 scripts/benchmark_android_aware.py --guide 66180DLKX006ND --guest 2A111FDH2007A1 --preflight-only

# Existing benchmark, both roles, 3 x 10 seconds per mode.
bash scripts/benchmark_android_aware.sh --guide 66180DLKX006ND --guest 2A111FDH2007A1

# Actual Aware tour; repeat with guide/guest reversed.
GOH_NEARBY_TRANSPORT=aware GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh

# BLE disabled-Wi-Fi fixture; restores original Wi-Fi settings.
GOH_NEARBY_WIFI_OFF=1 GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh

# Boot dedicated simulator before the full virtual gate.
DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer xcrun simctl bootstatus B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98 -b
GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer GOH_IOS_DERIVED_DATA=/tmp/GetOverHereSignatureIOS GOH_IOS_DESTINATION='platform=iOS Simulator,id=B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98' ANDROID_SERIAL=emulator-5554 bash scripts/verify_virtual_devices.sh
```

Benchmark shell normally builds after preflight. `--smoke-only` runs emulator regressions but still preflights the physical pair. `--reuse-installed` (benchmark) and `GOH_NEARBY_REUSE_INSTALLED=1` (tour) verify exact app/test APK hashes; omit reuse after changes. [Cross-platform fixture](scripts/verify_nearby_cross_platform.sh) exists but no physical run completed; inspect preflight/roles before use with an authorized iPhone.

Never overlap physical installs/tests on the same pair or edit executing harness/app/test sources. Use bounded background jobs/named logs, report progress, and check completion without busy polling. Prior CoreSimulator restart approval is not continuing authority to restart shared services. Preserve unrelated edits; do not touch unrelated sockets/processes or clean shared caches/devices.

## Pending decisions and next concrete action

- **D1:** Actual pairing SDK/runtime/hardware support and Apple interoperability in both roles; precise `-11992` operation.
- **D2:** Small-packet transport choice and latency cause; native codec PLC/FEC controls must be checked before promising them.
- **D3:** Admission key-binding/first-contact trust profile; reviewed PAKE and individual revocation are separate decisions.
- **D4:** Measured direct cap, relay topology, background policy, battery/acoustic thresholds; no fixed 30-person claim.
- **D5:** Mandatory router, new LAN multicast lane or OS-baseline change needs explicit direction, not automatic research adoption.

**Start with A1:** inspect/extend `AwarePhysicalBenchmarkTest`, `AwareBenchmarkProtocol` and active native Aware owner for resource counters/tiny-packet comparison, preserving passing bulk mode. During initial read-only inspection check SDK/runtime eligibility for A2. Continue A3/A4 software without repeatedly requesting unavailable iPhone tests. No A1–A4 implementation was started by this documentation request.
