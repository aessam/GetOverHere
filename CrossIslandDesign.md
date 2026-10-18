# Cross-island design: one Bluetooth bridge, platform-native P2P islands (ADR-081)

Status: design, 2026-10-17. Synthesized from three read-only design passes (iOS island, Android island,
bridge protocol). Nothing here is implemented. Unverified platform behavior is marked UNVERIFIED.

## Target

- Exactly one heterogeneous link per tour: one iPhone ⇄ one Android over BLE L2CAP (the path proven in Phase 5).
- Every other link is same-platform peer-to-peer: iOS⇄iOS and Android⇄Android. No AP, no hotspot, 0 bytes
  to the internet.
- The guide may be on either platform. All four paths are covered: iOS→iOS, Android→Android, iOS→Android,
  Android→iOS.

## Topology (fits `BoundedSessionTopology.maximumDepth = 2`, no core constant change)

```
guide (depth 0)
 ├── same-platform guests, direct P2P            (depth 1, near island)
 └── BLE L2CAP ── bridge = first other-platform guest with relayHost   (depth 1)
                   └── its same-platform guests, direct P2P            (depth 2, far island)
```

- DSCN-1: the guide is always the near end of the single BLE link. The far end is the first admitted
  other-platform guest that advertises the new `relayHost` capability. One relay node per tour. All three
  passes converged on this.
- DSCN-2: both islands are stars in v1. A relay inside an island would be depth 3; revisit only if the
  measured star cap fails (QST-4).

## Island carriers

| Island | Primary | Floor | Measured / documented | Fallback |
|---|---|---|---|---|
| iOS⇄iOS | Apple peer-to-peer Wi-Fi (AWDL): `NWParameters.includePeerToPeer` + Bonjour `_goh-peer._tcp`; `ApplePeerRoomTransport` exists | iOS 12+ (meets the iOS 17 floor), no pairing | throughput and lock behavior UNVERIFIED (Apple documents neither) | BLE L2CAP (0.25–0.53 Mbps measured) |
| Android⇄Android | Wi-Fi Aware data paths (`_goh-andr._tcp`) | API 34 app gate, Aware hardware | Pixel 7/11: 8 NDPs, ~300 Mbps one peer (benchmarks/2026-09-10) | BLE L2CAP leaf, API 29+ (0.16–0.65 Mbps), audio + control, slides from packs |

- Wi-Fi Aware on iOS stays a later upgrade: Apple documents iOS 26.0 + iPhone 12, but it needs per-pair
  pairing (QST-7 on the repo's 26.4 guard).
- MultipeerConnectivity stays deleted (ADR-050): Apple's TN3151/TN3213 deprecate it.
- Wi-Fi Direct / LocalOnlyHotspot stay unselected: lesson 37 instability, and Android docs warn Aware may be
  unavailable while Direct or SoftAP is in use.
- Star cap planning number: 8 per island root (Pixel NDP limit; AWDL undocumented). Raise only on evidence.

## Relay protocol (bridge node)

The bridge subscribes upstream once as an ordinary guest and fans frames out downstream; it never tunnels
per-guest byte pumps (that would put N copies on the one BLE link).

| Lane | Rule |
|---|---|
| Admission | GOHR v2 forwarded byte-for-byte to the guide on a short-lived BLE channel (≤ 4 concurrent). Guide key pinned end to end; the bridge never sees the media secret. ADR-052/059 unchanged. |
| Realtime | Verify GOS1, drop duplicates (envelope identity + sealed digest), forward the same bytes to each child writer; ≤ 50 ms residence per hop. |
| Control | Cache the latest guide-signed snapshot per kind; replay to each new far guest locally (joins cost 0 BLE bytes). Liveness comes from guide-signed frames, not the bridge link. |
| Asset | Forward the signed manifest; prefetch each hash once (current slide first, ADR-078/079 pacing on BLE); serve chunks from the bridge cache. A far guest accepts a chunk only for a hash in the authenticated manifest and keeps the file only if its SHA-256 matches (same rule as tour packs, ADR-080). |
| Upstream (guest → guide) | Heartbeat, `audioStatus`, `leave` multiplexed on the bridge's control channel; the guide treats them as advisory counts (shared-key frames can be forged by any member). |

- Exactly one bridge: the guide issues a GOS1-signed `bridgeAssignment` (generation, bridge ID, lease,
  ≤ 2 standbys) and rejects a second cross-platform lane set. Loops are impossible: frames only flow
  down, far guests never host.
- Failover: 1 s heartbeat / 3 s timeout; the first standby (already admitted, in BLE range of the guide)
  takes the slot, the guide publishes generation + 1, island guests move to the higher generation.
- A bad signature on a relayed route is a route fault (drop link, fail over), not a terminal session
  failure (amends the ADR-059 terminal rule for relayed routes only).

## Wire changes (both cores, same patch, fixtures, `scripts/verify_tour_session.sh`)

W1 `bridgeAssignment` kind · W2 `relayHost` capability bit · W3 room record gains host ID, bridge
generation, `bridgeTaken`, free slots (today discovery keeps only the first advertiser per room) · W4 relay
lane handshake (membership proven with the shared credential; welcome sealed by the bridge, valid only on
relay lanes) · W5 upstream multiplex record · W6 peer-served `assetChunk` acceptance by manifest hash.
Admission bytes do not change.

## Capacity of the single BLE bridge link (measured inputs)

| Item | Load | Grows with far-island size? |
|---|---|---|
| Link capacity | 31–66 kB/s | — |
| Audio (batched Opus + GOS1) | 7.4 kB/s | no (sent once, fanned out) |
| Control + heartbeats | < 0.5 kB/s | no |
| Slides, paced | ≤ 20 kB/s, only while a hash is missing | no (once per hash) |
| Upstream advisory frames | ~40 B/s per far guest | yes |
| Cold 20-page deck (5.1 MB) | 315 s once for the whole far island | — |
| Headroom with slides flowing, worst link | ~3 kB/s | — |

The bridge link cost is constant in the far island's size; the island's limit is the bridge's own fan-out
(8 Aware paths on Pixels). Tour packs (ADR-080) turn the deck and map into 0 bridge bytes and leave the
margin to audio, so they ship before or with the relay.

## Code gaps found

- Android discovery is advertise-or-browse; a bridge must do BLE guest + Aware host at once.
- Guest adapters and guide lanes bind the same local ports (50000–50003): one process cannot be both.
- No frame forwarder exists; `BoundedSessionTopology` is unused by the apps.
- `ChannelService` (both platforms) assumes one role per process.
- Server send path always seals (`sealedOutboundFrame`); forwarding needs an `enqueueForwarded(bytes)` path.

## New interfaces (protocol first)

- Cores (Swift + Kotlin, parity fixtures): `RelayForwarder` (dedup window, snapshot cache, residence
  bound), `PeerAssetAcceptance`, `ParentSelectionPolicy`.
- Apps: `GuideFrameRelayInterface`/`Impl`, `IslandLinkInterface` (`AwareIslandLinkImpl`,
  `ApplePeerIslandLinkImpl`, `BluetoothIslandLinkImpl`), `ContentAddressedAssetServerInterface`,
  `BridgeAuthorityInterface` (guide), `IslandRoleCoordinatorInterface` (root / bridge / leaf).

## Phases (behind the experimental flag)

0. Tour packs (ADR-080) — removes most bridge load; independent of relay.
1. Cores: W1–W6, `RelayForwarder`, `PeerAssetAcceptance`, fixtures.
2. Android as bridge (iPhone guide): island host mode, Aware host + BLE guest in one process.
3. Guide `BridgeAuthority`; guest island discovery, liveness, failover.
4. iPhone as bridge (Android guide) over AWDL.

## Physical test matrix (I1 iPhone 13 Pro, I2 second iPhone, P7 Pixel 7, P11 Pixel 11)

| # | Guide | Bridge | Near guest | Far guest | Proves |
|---|---|---|---|---|---|
| T1 | I1 | P7 | I2 (iOS→iOS, AWDL) | P11 (iOS→Android→Android) | audio, slides, cold assets; bridge bytes ≈ deck once |
| T2 | P7 | I1 | P11 (Android→Android, Aware) | I2 (Android→iOS→iOS) | reverse direction |
| T3 | I1 | P7 then P11 | — | P11 | bridge killed/locked: gap ≤ 15 s, no duplicate playout, one generation step |
| T4 | P7 | I1 then I2 | — | I2 | locked iPhone as island host |
| T5 | I1 | P7 | — | P11 tries direct BLE to I1 | rejected: exactly one bridge |
| T6 | either | either | — | far guest with tour pack | ready < 5 s, 0 asset bytes over BLE |
| T7 | either | either | — | far guest, locked room | right code admits, wrong code fails, no secret in bridge logs |
| T8 | I1 | P7 (debug byte flip) | — | P11 | route fault → failover, guest stays in session |

Each step records PASS / FAIL / NOT RUN in `ExperimentLog.md`.

## Risks

- R1 BLE + AWDL/Aware coexistence on the bridge's shared radio may throttle the one BLE link.
- R2 AWDL and Aware behavior with the screen locked or in Doze is undocumented (may need ADR-076 keep-awake
  on island roots and the bridge).
- R3 Aware/AWDL jitter tail (Aware loaded p95 150–240 ms) vs the 120 ms Opus target.
- R4 Local Network permission denied or never prompted silently breaks the iOS island (TN3179).
- R5 Share of Androids without Aware / below API 34 is unknown; they become BLE leaves.

## Open questions

- QST-1 Far-guest readiness: accept advisory counts relayed by the bridge, or add per-guest authentication
  from the admission exchange first?
- QST-2 Android island: derive the Aware PSK from the media credential (removes the 6-digit PIN; wire +
  fixtures) or keep the PIN?
- QST-3 Relay-aware admission deadline: two hops + up to 35 s Aware setup vs ADR-052's 5 s.
- QST-4 If an island outgrows 8, allow a depth-3 same-platform sub-relay (core constant change)?
- QST-5 Per-chunk hashes in the manifest to catch corrupt chunks before a whole-file refetch?
- QST-6 Second iPhone model (Aware needs iPhone 12+); is "Pixel 11" the Pixel 11 Pro `66180DLKX006ND`?
- QST-7 Why the repo guards Wi-Fi Aware at iOS 26.4 when Apple documents 26.0.
