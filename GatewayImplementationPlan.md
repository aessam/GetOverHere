# Two-hub gateway implementation

Approved September 11, 2026. This is the execution checklist for the two-phone
gateway plan; checked items require retained verification evidence.

## Agreed product decisions

- Either iPhone or Android owns the microphone and all tour authority. The other
  phone is a companion gateway. No mid-tour authority transfer.
- Two hubs only; no audience relays, mesh, election, or relay tree. Aim toward
  thirty listeners but publish only the physically qualified model/orientation/
  platform-split capacity. The companion does not consume an audience slot.
- Listeners must work locked. Active guide capture must be qualified locked.
  The companion may use explicit production keep-awake, restored on stop.
- USB is the cross-platform link. Apple Network.framework peer-to-peer is the
  iOS branch; Android Wi-Fi Aware is the Android branch. Radios remain enabled;
  no access point or Internet dependency and no Wi-Fi-radio-disabled claim.
- Preserve LAN/Bluetooth, open rooms, editable optional code locking, admission
  v2, guide-key continuity, signed immutable frames and verified asset resume.
- PAKE replacement, individual revocation, Auracast, mixed Aware interoperability,
  shared-upstream multiplexing and companion asset caching are not this scope.

## Architecture and ownership

UI/coordinators depend on application services, then transport interfaces and
the mirrored Swift/Kotlin session core. Platform transports own sockets/radios.
Debug adapters call real services; production does not depend on debug control.

Each listener has independent duplex admission/realtime/control/asset lanes.
The companion's existing NearbySocketBridge connects each lane through USB to
the original guide's fixed application service, not to a second tour/producer.
The guide authenticates each leaf and encodes/signs once per codec. Companion
does not obtain tour media credentials, sign, decode or re-encode. Reverse
readiness and asset requests retain actual listener identity.

Contracts: GuideLaneConnector, WiredCompanionTransport, ApplePeerRoomTransport,
GatewaySessionCoordinator, GatewayRoomDescriptor, RouteProvenance and
AllowedTransportPolicy. Preserve original guide identity/platform separately
from provider identity/platform. Native endpoints retain IPv6/service scope.

Wired enrollment uses mutually pinned TLS 1.3 with separate hub identities,
two-way public-fingerprint QR exchange, one fresh pairing identifier, two-minute
incomplete enrollment expiry and final guide confirmation. No accept-all trust,
shared tour key as companion authority, private-key QR or arbitrary TCP proxy.
Guide is TLS listener in either orientation. Each authorized TLS connection
selects only a fixed lane; guide ingress connects to its local service. Explicit
association removal revokes every associated connection. iOS identity generation
uses Security and Apple Swift Certificates; Android uses AndroidKeyStore/JSSE.
Keep iOS17/Android26 application floors; TLS1.3 hub capability is separately gated.

Never hardcode observed USB IP/interface names or bind the whole Android process
to one network. Select each Aware socket's native Network independently from USB.
Apple includePeerToPeer permits but does not force P2P: physical qualification
requires unassociated iPhones plus captured endpoint/path evidence. Unknown or
fallback provenance cannot pass strict qualification.

Forward complete unchanged application frames; native zero-length ACK records
remain radio-hop-local. Drain final admission replies. At most eight queued
audio frames and initially50ms local gateway residence; blocked writers have
deadlines. Gateway cannot inspect encrypted capture expiry. Listener source-age
checks and measured clock uncertainty remain separate from gateway dwell.
Keep control/assets reliable and preserve existing current-content/hash/resume
behavior. Bound forwarded admission to four of the guide's global eight pending
slots. Account audience, pending work, proxy halves and radio paths separately.

## Execution and proof

September15 review repairs: F1–F12 in `SecurityCodeReview-2026-09-15.md` are
implemented with software regressions. All nine repository gates, native Android
emulator fault tests and cross-runtime TLS tests pass. Current evidence and build
identities: `benchmarks/2026-09-15-security-review/README.md`. Physical acceptance
below remains unchecked; neither simulator nor local TLS substitutes for it.

Software candidate verified September11. Evidence and exact counts:
`benchmarks/2026-09-11-gateway-software/README.md`. Checked software work does not
check its physical acceptance row. The user is away from the devices; A6 is NOT RUN.

- [x] A1 software: Reproduce/instrument Android encoder startup/reset churn,
  correct accepted-input accounting and bounded stale-output drain, retain tests.
- [ ] A1 physical: Verify ordinary application USB TCP both roles; USB+Aware and USB+Apple P2P
  coexistence without AP/Internet. Record USB power/data roles. Unsupported
  hardware is explicit, not silently routed through LAN.
- [x] A2 software: Mirrored contracts/negative fixtures, TLS enrollment, fixed-lane proxy,
  limits, generation ownership and admission-flood isolation.
- [x] A3 software: Apple native peer adapter, Android Aware companion integration,
  authoritative metadata publication and strict route policies.
- [x] A4 software: Guide/companion/listener UI; truthful connected versus audio-ready
  counts; Android connectedDevice lifecycle; permissions at user intent.
- [x] A5 software: Loss/replacement lifecycle, retained guide pin, state repair and
  exact asset resume, stale-callback rejection and bounded audio queues. Real TLS
  component tests exercise changed addresses; actual cable/radio faults await A6.
  Coordinated source, builds, tools and evidence are ready for consolidated acceptance.
- [ ] A6 physical: Both orientations, actual cable/radio recovery, capacity, lock, acoustic and endurance
  qualification. Four phones prove both branches, not capacity.

## Debugging and reusable tests

- Extend existing iOS authenticated debug bridge and add Android debug adapter
  with matching semantics against actual application services. No substitute
  coordinator or remote shell. Release excludes debug activation/commands.
- scripts/verify_gateway_system.py: explicit manifest, preflight, smoke, run,
  collect, report and resume; device/OS/build hashes, roles, route expectations,
  radio state, seeds and positive actual test counts. Reject competing tests,
  occupied user tours, wrong artifacts and required-test skips. Retain failures.
- Optional fixed-destination Android debug passthrough to iPhone TLS over USB,
  preserving end-to-end debug authentication; no arbitrary proxy destinations.
- Bounded on-device scenarios with local Start/Cancel, local evidence and later
  export. Mac connectivity is optional; debugger keep-awake cannot pass locks.
- Seeded transport faults: delay, blocked writer, EOF, corruption, duplicates,
  malformed framing and stale callbacks. Real radio/lock faults stay physical.
- Acoustic analyzer validated against known-delay recordings, then external
  simultaneous microphone/reference/output recordings; never RTT/2.
- Bounded one-second metrics and failure trace: session/route generation,
  interfaces/Network, capture/codec/reset counters, frame/queue/write counts,
  rejects, renderer/readiness, assets, lifecycle, battery/power/thermal.
  No secrets, personal identifiers/content or raw microphone audio by default.

Software gates: Swift Testing/JUnit exact cross-language fixtures, actual UI
XCTest/Compose, wrong pins/certs/enrollment replay, wrong codes, lock races,
identity preservation, byte-identical forwarding, per-leaf isolation behind one
IP, ACK boundaries, admission drain, queue/flood bounds, asset repair, route
replacement, Release exclusion and existing LAN/Bluetooth regressions.

## Proposed acceptance targets (not measurements)

| Dimension | Target |
|---|---|
| Startup |30 consecutive cycles per orientation, no unexplained encoder churn; accepted PCM within5s after admission|
| Smoke |10min real capture and playback on every required route|
| Acoustic |p95<=180ms, p99<=250ms in healthy operation; headphone skew p95<=40ms|
| Continuity |Lost/expired<=1% per listener/min; no unexplained>=400ms outage|
| State/assets |Cached current state visible p95<=500ms; exact resume/hashes; asset load raises audio p95<=10%|
| Cable loss |Local branch continues; failed companion visible<=3s after detected loss|
| Recovery |Playback p95<=5s after native/wired path restored; separately report link restoration|
| Locked |Real speech, several minutes silence/pause, resumed speech and supported interruptions|
| Endurance |30min stress then90min walk; no unexplained disconnect/resource growth/thermal QoS failure|
| Power |Start>=80%, finish90min>20%, no external charging except hub USB power; record both directions|

Intentional faults use recovery gates, not exclusion from evidence. Test iOS-
heavy, Android-heavy and both branches together, capacity-1/capacity/capacity+1,
locked and weak-edge guests plus asset traffic. Reject overflow without evicting
healthy listeners. Largest physical passing configuration is the published cap.

## Completion boundaries

USB/radio incompatibility blocks that hardware; failed locked listeners or audio
quality blocks release. Below30 capacity is acceptable with accurate declared
limits. Missing devices means physical rows NOT RUN, never simulator substitution.
Deliver integrated builds, tools, raw evidence, generated matrix, supported caps,
one field checklist and updated ADR/ExperimentLog/LessonsLearned/NextSession.
Retain research archives and the stable LAN tag. Commit tested milestones.
Coding complete and physically qualified are distinct outcomes.
