> Archive provenance: user-supplied Claude research report, self-dated 8 September 2026. The report body below is preserved as supplied, including its claims, contradictions, and source list. It is research input, not an accepted implementation specification or independently verified test evidence. Read the current synthesis and corrections in [NextSession.md](NextSession.md) before acting on it. The report's date is its author's label, not a new local experiment date.

---

# GetOverHere: Offline Cross-Platform Tour-Guide Audio for 30 Phones — Architecture Decision & Validation Plan

**Research performed:** 8 September 2026. All API/OS/hardware claims are stated as of this date. Tool note: Google Drive/Gmail/Calendar/Hugging Face connectors were not reachable in this session; no ADR.md/ExperimentLog.md/LessonsLearned.md could be read. The verbatim brief is treated as authoritative project-state data.

Label key: **[DOC]** documented in primary source; **[MEAS]** measured in your lab (from brief); **[INF]** inferred; **[CONTRA]** contradicted; **[UNK]** unknown.

---

## TL;DR

- **All-Android:** feasible now via **replicated unicast over per-peer Wi-Fi Aware data paths** + BLE discovery/control + app-layer AEAD/P-256 signing, with a bounded relay tree past the guide phone's data-path ceiling. **iOS↔iOS:** works with paired peers (iOS 26+), but **iOS guests drop when the phone locks** (no Aware background).
- **Mixed iOS+Android without an access point is NOT reliable today:** Apple mandates system pairing (6-digit PIN) and Android↔iOS Wi-Fi Aware NDP completion is repeatedly reported to fail. There is **no public broadcast primitive** (not Aware multicast, not IP multicast without an AP, not LE Audio/Auracast from a phone app) that lets you "encode once and have 30 unpaired phones receive it."
- **Decision (D1):** ship BLE control + Wi-Fi Aware unicast-fan-out (per platform) as primary, keep the **shared-LAN transport as the preserved baseline and the only currently-viable mixed-platform path**, and gate router-free-mixed behind experiments, not launch promises.

---

## 1. Executive verdict

**Bottom line:** Yes — one guide can deliver live audio to ~30 mixed phones outdoors without an access point, but ONLY via **replicated unicast over per-peer Wi-Fi Aware data paths (Android) plus, separately, per-peer paired Wi-Fi Aware connections (iOS 26+)**. There is **no public one-to-many "broadcast audio" primitive** available to ordinary third-party iOS/Android apps that does this without an AP. The desired "encode once, all 30 receive it" model is **unsupported** at the API layer; it must be emulated by the app replicating unicast per peer (or via a relay tree).

- **Feasible now (documented + your measurements):**
  - Android↔Android: open/PIN NDP data paths, TCP/UDP sockets, ~300 Mbps single-link goodput measured. Star fan-out to many Android guests is buildable today.
  - iOS↔iOS: WiFiAware framework (iOS 26), paired peers, Network.framework connections.
  - BLE control/discovery + L2CAP fallback cross-platform (your fixtures pass Android↔Android).
- **Requires experiments (not yet proven):**
  - 30-way concurrent NDP fan-out on one guide phone (NDP/airtime ceiling unproven).
  - Microphone-to-speaker acoustic quality; locked-phone capture/playback; endurance; movement recovery.
  - Latency-tail root cause (your 155–171 ms idle p95).
- **Unsupported / do not pursue as core:**
  - Android↔iOS Wi-Fi Aware interop (not established; multiple failure reports).
  - LE Audio/Auracast broadcast transmit or receive from a third-party phone app.
  - Wi-Fi Aware with the Wi-Fi radio disabled.
  - Any "send one packet, 30 unpaired phones receive" API.

**Primary decision (D1):** Ship the **BLE discovery/control + Wi-Fi Aware unicast-fan-out (Android) / paired-peer (iOS) media plane**, keep the LAN transport as the preserved baseline and as the *only* currently-viable mixed-platform high-bandwidth path (shared Wi-Fi AP), and treat router-free mixed iOS/Android as an experiment-gated future, not a launch promise.

---

## 2. Claim audit

- **F1 [DOC]** Wi-Fi Aware/NAN public APIs expose **peer-to-peer discovery + point-to-point data paths only**; no app-level group/multicast data path. (Android developer docs; Apple WiFiAware docs.)
- **F2 [DOC]** Android NDP is unicast point-to-point; serving N peers needs N data paths. Android 12+ "accept any peer" reduces *setup requests* to one but still creates **multiple point-to-point links**, not one shared link. (developer.android.com/develop/connectivity/wifi/wifi-aware.)
- **F3 [DOC]** Apple WiFiAware (iOS 26) **requires pairing** before any data path; pairing uses a system UI and a six-digit PIN; there is no open datapath and no passphrase mode on iOS. (Apple WiFiAware docs; Espressif iOS-26 interop writeup; Apple DevForums 791628, 790195.)
- **F4 [CONTRA/UNK]** "Pixel max of eight NAN data paths" is a **device/firmware-specific observation, not a universal limit**. The legacy HAL exposes `u32 max_ndp_sessions` inside `NanCapabilities` (`hardware/libhardware_legacy/.../wifi_nan.h`, verbatim-confirmed on AOSP googlesource), populated by vendor firmware; **no primary source gives a fixed default value of 8** — treat the "8" as unverified. Runtime truth = `AwareResources.getAvailableDataPathsCount()` (API 31) / `Characteristics.getNumberOfSupportedDataPaths()` (API 33).
- **F5 [DOC]** Android↔iOS Wi-Fi Aware interop is **not an established contract**. Apple DTS: "it's rare to find hardware and software combinations that follow all of those guidelines"; multiple developers report pairing callbacks succeeding (`onPairingSetupSucceeded`, state `authenticated`) but the NDP never completing (Apple does not answer the Android NDP request). Apple stores a paired peer by NMI and treats NMI/NDI as the same; Qualcomm/Android distinguish them. Aware Pairing (WFA v4.0, `isAwarePairingSupported()`) was reported present on very few Androids (e.g. Galaxy S25 in one report; Pixel 9 / Xiaomi 14 reported not). (Apple DevForums 790195, 796446.)
- **F6 [DOC]** LE Audio/Auracast broadcast is **not usable by third-party phone apps as a transmitter or receiver of arbitrary audio**: since Android 13 third-party apps are blocked from LE Audio GATT services incl. Broadcast Audio Scan Service (BASS); the assistant API (`BluetoothLeBroadcastAssistant`, Android 16) only steers a *paired LE Audio sink* (hearing aid/earbuds), not the phone's own speaker/app. Auracast receivers are earbuds/hearing aids, not a second phone's app. (Bluetooth SIG; Android docs; dev.to broadcast-assistant writeup.)
- **F7 [MEAS]** Android↔Android Aware single-link goodput: median 300–307 Mbps one-way, ~181–186 Mbps duplex; peak 326.61 Mbps; idle RTT p50 14.6–17.5 ms, p95 155–171 ms; loaded duplex p95 up to 234 ms; 4-channel setup ~2.1–4.0 s. Phones awake/unlocked/foreground; Wi-Fi radios enabled; no LAN fallback; synthetic payload, no AEAD/codec. (Your commit 7dca55f, 2026-09-07.)
- **F8 [INF]** 300 Mbps two-phone throughput **does not establish** 30-phone capacity: bandwidth is not the binding constraint; per-peer NDP scheduling, shared airtime, power-save peers, movement, and 30× replicated AEAD+signature CPU are.
- **F9 [DOC]** `NWError.wifiAware(-11992)` meaning is **[UNK]** — no public source defines this numeric code. Observed generically on publisher/listener start in DevForums 791898 ("failed(-11992: Wi-Fi Aware)"). Do not assign it a meaning.
- **F10 [DOC]** iOS WiFiAware runs as a **concurrent** interface (does not drop the phone's infrastructure Wi-Fi association); iPhone 12+ on iOS 26. (Espressif; Apple.)
- **F11 [DOC]** iOS WiFiAware has **no background/state-restoration model**; Apple DTS: if the app is suspended the connection closes, and idle Aware connections are garbage-collected after "a few minutes." (Apple DevForums 787570.)
- **F12 [DOC]** Your P-256 sign-once/verify primitives match the correct construction for broadcast source authentication (asymmetric signature so relays/guests cannot forge), the only issue being trusted key delivery — a real, unsolved gap.

---

## 3. Platform / API matrix

| Capability | Android | iOS |
|---|---|---|
| Wi-Fi Aware API | `WifiAwareManager`, `PublishConfig`/`SubscribeConfig`, `WifiAwareNetworkSpecifier`, `ConnectivityManager.requestNetwork` (API 26+; enhancements API 31/33) **[DOC]** | `WiFiAware` framework + `Network.framework` (`NetworkListener`/`NetworkBrowser`/`NetworkConnection`); pairing via `DeviceDiscoveryUI` or `AccessorySetupKit` **[DOC]** |
| Min OS / HW | Android 8 (API 26); instant-comm mode API 33; "accept any peer" API 31. Device must advertise `FEATURE_WIFI_AWARE` **[DOC]** | iOS 26; iPhone 12 and later; various iPads **[DOC]**. Your project gate is iOS 26.4 with an iOS 17 baseline for other features — verified: WiFiAware itself is iOS 26+, and multi-connection-per-association is new in iOS 26.4 beta **[DOC]** |
| Pairing required | No (open NDP or PSK passphrase) **[DOC]** | **Yes**, mandatory, system UI + 6-digit PIN **[DOC]** |
| Open/unauth data path | Yes (`createNetworkSpecifierOpen`) **[DOC]** | No — always paired + Aware Pairing security **[DOC]** |
| One-to-many data path | **No** — per-peer NDP only **[DOC]** | **No** — per-paired-peer connections; multi-connection over one association only iOS 26.4 beta **[DOC]** |
| Entitlements | Manifest perms: `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `CHANGE_NETWORK_STATE`, `NEARBY_WIFI_DEVICES` (API 33+, `neverForLocation`), `INTERNET` **[DOC]** | `com.apple.developer.wifi-aware` entitlement; `WiFiAwareServices` Info.plist keys **[DOC]** |
| Background/locked | Foreground service types mandatory (Android 14+): `microphone` cannot start from background; `connectedDevice`/`mediaPlayback` for relay/playback **[DOC]** | No Aware background mode; connection dies on suspend; idle GC after minutes **[DOC]** |
| Aware + Wi-Fi radio | Requires Wi-Fi radio ON; may be unavailable if SoftAP/Direct/tether active; concurrency is `WIFI_HAL_INTERFACE_COMBINATIONS` (often 1 NAN *or* P2P) **[DOC]** | Requires Wi-Fi ON; concurrent with infra Wi-Fi **[DOC]** |
| NDP concurrency ceiling | `max_ndp_sessions` (vendor firmware) → query `getAvailableDataPathsCount()`; **no fixed public number** **[UNK]** | No documented max simultaneous paired connections **[UNK]** |
| LE Audio/Auracast transmit from app | **No** (BASS restricted since Android 13) **[DOC]** | No public transmit API **[DOC]** |
| BLE L2CAP CoC (fallback lane) | Public API since **Android 10** **[DOC]** | Public API since **iOS 11** (`CBL2CAPChannel`) **[DOC]**; real constraint is OS-version coverage + low throughput, not API absence |
| IP/link multicast without AP | Not over Aware (unicast NDP); shared-LAN multicast needs an AP and, on iOS, the `com.apple.developer.networking.multicast` entitlement (Apple approval) **[DOC]** | Same; iOS multicast entitlement is restricted/approval-gated **[DOC]** |

---

## 4. Central question — can broadcasting solve group size?

**No, not through any public broadcast primitive.** Auditing the disallowed conflations:

- **Discovery advertising / messaging** (NAN publish/subscribe, `sendMessage` ≤255 B): one-to-many *discovery* exists, but it is not media transport and is rate/size-limited. **[DOC]**
- **IP broadcast / IPv6 multicast / link-layer multicast:** available only on a real IP subnet (needs an AP/LAN); over Wi-Fi, multicast is unreliable (no ACK, no power-save buffering) per RFC 9119; and Aware NDPs are point-to-point IPv6 links, not a shared multicast segment. On iOS, custom multicast needs the restricted multicast entitlement. **[DOC]**
- **Replicated unicast:** the only mechanism that works today — app encodes once, then transmits N copies over N NDPs. Cost is CPU + airtime, not a missing API. **[INF]**
- **Application-level flooding / relay trees:** viable to extend range/fan-out beyond one device's NDP ceiling; must be bounded (no unbounded mesh). **[INF]**
- **BLE LE Audio/Auracast:** the one true "encode once → unlimited receivers" radio primitive — but F6 shows phone apps cannot transmit it and a second phone cannot receive it into the app. **[DOC/CONTRA]**
- **Wi-Fi Aware publish/subscribe terminology** ≠ data broadcast. **[DOC]**

The prior assistant's claim ("Android exposes peer-specific Aware connections, not a general nearby audio-broadcast operation") is **correct and now corroborated** by AOSP docs and the HAL model (per-peer NDP with per-peer security context). It is exhaustive for shipping public APIs. **[DOC]**

---

## 5. Research questions

### Q1 — One-to-many API support
- NAN standard **defines** multicast group concepts only in SRDs/patents (e.g., US 10,271,180 "NAN multicast support," which explicitly notes "current NDP and NDL setup protocols are designed for unicast"); **not exposed** in Android or Apple public APIs. **[DOC/patent]**
- Android exposes per-peer NDP; a single `requestNetwork` with "accept any peer" yields **multiple point-to-point links**, not one group link. **[DOC]**
- A third-party app **cannot** send one payload to multiple unpaired nearby phones over Aware. **[DOC]**
- Multicast-style delivery still requires **per-peer NDP + per-peer security context**. Wildcard/"any peer" reduces *admission friction*, not NDP count. **[DOC]**
- Multiple sockets to one peer multiplex over **one NDP** (separate TCP/UDP ports, same data path). Separate sockets ≠ separate radio QoS. **[INF, matches brief]**
- A phone can concurrently publish + subscribe (docs say so), but simultaneous publish+subscribe+receive+relay is resource-bound by `max_ndp_sessions` and HAL interface combinations. **[DOC + UNK ceiling]**
- Concurrency limits: `getAvailableAwareResources()`, `getAvailableDataPathsCount()`, `getNumberOfSupportedDataPaths()` at runtime; the specific numbers are **vendor-specific and undocumented**. **[UNK]**

### Q2 — Android↔iOS interoperability
- **Service naming:** both use NAN service names (Apple `WiFiAwareServices` Info.plist e.g. `_service._udp`; Android `setServiceName`). Nominally alignable. **[DOC]**
- **Discovery:** both are NAN publish/subscribe; can match in principle. **[DOC]**
- **Pairing/bootstrapping:** the blocker. Apple **mandates** its Aware Pairing (6-digit PIN, system consent, stored by NMI). Your Android side uses PIN-secured NDP or open/PSK. Interop requires the Android device to implement **Wi-Fi Aware Pairing (WFA spec v4.0, `isAwarePairingSupported()`)** — reported present on very few devices. Even then, end-to-end pairing + NDP has been reported to fail (pairing callbacks succeed, NDP request unanswered by iOS). **[DOC]**
- **Cipher/KDF:** Apple internal to Aware Pairing (SK-128-class); Android PIN NDP is a different setup. Not established as interoperable. **[UNK/CONTRA]**
- **Endpoint/port publication:** Android advertises a dynamic TCP port via Aware metadata; Apple abstracts endpoints via Network.framework. Different models. **[DOC]**
- **Third-party vs accessory:** Apple's Aware is framed around device↔device and device↔accessory; both paths (DeviceDiscoveryUI, AccessorySetupKit) still require pairing. **[DOC]**
- **AirDrop/Quick Share/share-sheet:** privileged OS integrations; **not reusable** third-party transports. The observed Android↔iOS share-sheet transfer is not evidence of a public interop API. **[DOC, matches brief]**
- **Verdict:** Your PIN-secured NDP **cannot currently interoperate** with Apple's system-paired model without (a) implementing WFA Aware Pairing on Android, (b) a device that supports it, and (c) Apple resolving the NDP-response interop bug. **Do not gate launch on this.** **[INF]**

### Q3 — Thirty-person topology (ranked)

| Architecture | Mixed-platform | User steps | NDP/airtime | Battery | Movement | Background | Failure recovery | Security | Impl cost | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **BLE discovery/control + Aware audio/assets (Android); paired Aware (iOS)** | iOS/Android each within platform; cross-platform only on shared LAN | Low (open room) | Per-peer NDP; ceiling unproven | Med-high | Good (BLE re-discovery) | Constrained | Good | App-layer AEAD + P-256 | Med (mostly built) | **Primary (D1)** |
| **Direct Aware star** | Per-platform | Low | Bounded by `max_ndp_sessions` | High | Med | Constrained | Med | Same | Low | Overflow → relay |
| **Aware relay tree (bounded)** | Per-platform | Low | Distributes NDP load | High | Med | Hard (relay while locked) | Med | Needs authenticated relay | High | Overflow path |
| **Shared-LAN multicast** | **Yes (best mixed)** | Med (join AP) | AP handles fan-out | Low-med | Good | Good | Good | Your LAN baseline | Low (exists) | **Fallback / mixed-platform** |
| **Aware multicast/groupcast** | — | — | — | — | — | — | — | — | — | **Unsupported (no API)** |
| **BLE relay fallback (control only)** | Yes | Low | N/A | Low | Good | Med | Good | App-layer | Med | Control/degraded-audio only |
| **Hotspot / Wi-Fi Direct** | Partial | High (setup/power) | AP-like | High | Med | Med | Med | App-layer | Med | Rejected (friction; your instability) |
| **LE Audio/Auracast** | — | — | — | — | — | — | — | — | — | **Unsupported for phone apps (F6)** |

Do **not** adopt an unbounded mesh. If one guide phone cannot sustain N NDPs, use a **bounded relay tree** (1–2 hops, fixed fan-out) with authenticated relays (see Q5), not arbitrary flooding.

### Q4 — Audio timing and latency tails
Your idle median ~15–17 ms is healthy; the **p95 155–171 ms** (and loaded 234 ms) is the risk. Candidate causes (to isolate, not assume):
- **TCP delayed-ACK / Nagle interaction — prime suspect.** This is the canonical cause of stalls in exactly your p95 band. Per RFC 1122 §4.2.3.2, "a host may delay sending an ACK response by up to 500 ms," and on Linux the delayed-ACK timer runs `TCP_DELACK_MIN` 40 ms to `TCP_DELACK_MAX` 200 ms — bracketing your 155–171 ms spikes. Stuart Cheshire's canonical analysis of the Nagle/delayed-ACK interaction warns "all these huge 200 ms pauses can be devastating to an application protocol"; RFC 896 (Nagle) plus a short packet after an odd number of full-MSS segments on a persistent connection reproduces the ~200 ms delay. Small, bursty Opus frames are precisely this pattern, so your 150 ms drop rule is fighting TCP semantics. **[DOC mechanism / INF]**
- **Aware availability windows / power-save:** discovery windows and NAN scheduling introduce periodic wake latency → tail spikes. **[INF, DOC mechanism]**
- **Loopback adapter buffering/scheduling:** your Nearby lane adapts app streams through local loopback sockets — extra queueing/scheduling jitter. **[MEAS-adjacent]**
- **Coexistence** with infra Wi-Fi/BT on a shared radio. **[INF]**
- **CPU scheduling** (foreground vs contended). **[INF]**
- **Measurement design:** the separate RTT socket may not reflect media-lane scheduling.

Transport choice for expiring speech: **prefer UDP** with app-level pacing, a small adaptive **jitter buffer**, **PLC** (Opus in-band), optional **FEC** (Opus in-band FEC / RFC 6363 flexible FEC), and no reliable retransmit for stale frames. TCP is a poor fit for realtime speech (head-of-line blocking + delayed-ACK tails). Distinguish: **network RTT** (measured) → **one-way network delay** (~½ RTT) → **mouth-to-ear** (capture + encode 20 ms + jitter buffer + decode + playout) → **inter-device playback skew** (add a shared playout clock/timestamp so guests stay within ~tens of ms of each other).

**Proposed acceptance thresholds (justified by ITU-T G.114, 05/2003):** G.114 states that "if delays can be kept below this figure [150 ms], most applications, both speech and non-speech, will experience essentially transparent interactivity," while "delays above 400 ms are unacceptable for general network planning purposes." Accordingly: one-way network delay p95 ≤ 50 ms; **mouth-to-ear p95 ≤ 150 ms (hard fail > 400 ms)**; jitter buffer target 40–60 ms; inter-device skew ≤ 50 ms; sustained frame loss < 1%.

### Q5 — Security without mandatory codes
- **Open-room admission** should grant *media decryption*, not *authority*. Your session credential is fine for confidentiality; it **cannot** authenticate the guide (F12). **[DOC]**
- **Session-scoped guide-key continuity:** pin the guide's **P-256 public key** at admission for the session lifetime; every guide frame carries a canonical low-S signature (your 8-byte wrapper + 64-byte sig). Relays forward **unchanged** signed frames → relays gain no authority. This is the correct construction (asymmetric = broadcast source auth; RFC 4082/TESLA states plainly that a symmetric MAC "is not secure" in a broadcast setting because "every receiver knows the MAC key and therefore could impersonate the sender"). **[DOC/INF]**
- **Malicious admitted guest:** cannot forge guide frames without the guide private key — provided the pinned public key was delivered trustworthily. **This delivery is the unsolved gap.** **[DOC]**
- **Optional short-code locking:** keep, but treat short codes as **low-entropy**; use a **PAKE (SPAKE2, RFC 9382, Sept 2023; or SPAKE2+ RFC 9383 / CPace)** so an offline dictionary attack on the code is not possible from passively captured traffic. Do **not** roll custom crypto. **[DOC]**
- **Replay/expiry/duplicates/nonce safety across routes:** monotonic per-session sequence + timestamp inside the signed frame; receivers keep a replay window; nonces unique per (session,key). Relays must not rewrite nonces. **[INF]**
- **Relay permissions & DoS limits:** relays authenticated to *forward* only; rate-limit per source; cap fan-out/hops. **[INF]**
- **Membership changes / revocation:** your current model cannot revoke a previously-admitted guest by changing the code; for real revocation you need **per-member keys / group rekey (sender-keys style)** — not implemented. State this as a known limitation. **[DOC]**
- **Cannot be authenticated without an independently trusted key or user verification:** guide identity. Options: out-of-band key display (QR/short fingerprint the guide reads aloud) *optionally*, or trust-on-first-use with session pinning. Be explicit that open rooms = TOFU, not verified identity. **[DOC]**

### Q6 — Locked phones & field use
- **Android:** foreground services with correct types are mandatory (Android 14+). `microphone` FGS **cannot be started from background** and needs `RECORD_AUDIO` while-in-use — so **guide mic capture must start while app is foreground**, then continue locked. Guest playback → `mediaPlayback`; relay → `connectedDevice`/`dataSync` (note dataSync 6 h cap on Android 15+). Declare types in Play Console. **[DOC]**
- **iOS:** **no Aware background execution**; suspends → connection closes; idle GC after minutes; no state restoration. Guests who lock the phone will drop unless another background reason keeps the app alive (and even then Aware GC applies). **This is a hard product constraint for iOS guests.** **[DOC]**
- Fresh discovery while locked: Android via FGS possible; iOS not reliably. **[DOC]**
- Reconnection after moving out of range / radio changes: design app-level re-discovery (BLE beacon + Aware re-request); Aware availability can change at any time (`ACTION_WIFI_AWARE_STATE_CHANGED`). **[DOC]**
- Older devices: not all advertise `FEATURE_WIFI_AWARE`; radios differ. Do not assume parity. **[DOC]**
- **Permitted-by-API ≠ reliable-under-power-management:** even where allowed, Doze/app-standby and OEM battery managers will curtail behavior; qualify per device. **[DOC/INF]**

### Q7 — Asset coexistence & capacity arithmetic
**Assumptions:** Opus 20 kb/s, 20 ms frames → 50 frames/s, ~50 B Opus payload/frame. Per-frame overhead: IPv6 40 B + UDP 8 B; AEAD tag 16 B; nonce/seq ~12 B; **P-256 signature wrapper 8 B + 64 B**.

- If **every 20 ms frame is signed**: payload ≈ 50 + 16 + 12 + 72 = **150 B app**, + 48 B IP/UDP = **~198 B on wire** → 50 fps × 198 B × 8 ≈ **~79 kbps per listener at IP layer** vs 20 kb/s codec — signatures **~quadruple** the media. **[INF]**
- **Recommendation:** sign at a lower cadence (e.g., every Nth frame or per 60–100 ms superframe) or use the AAC-LC 64 ms fallback (≈16 fps) to amortize the 64-byte signature; this cuts per-listener overhead sharply. **[INF]**
- **Aggregate (replicated unicast, 30 guests):** ~30 × 79 kbps ≈ **~2.4 Mbps egress** (worst case, per-frame signing) — **trivially within** the ~300 Mbps link capacity in raw bits. **[INF]**
- **Why 300 Mbps does NOT imply 30-phone capacity:** the 300 Mbps figure is a **single** point-to-point NDP, both phones awake/unlocked/foreground, unloaded channel, no AEAD/codec, no LAN fallback. Thirty guests require up to **30 concurrent NDPs sharing one radio and one airtime budget**, with power-save/locked peers, movement, discovery-window contention, and **30× per-frame AEAD + signature CPU** on the guide. The binding constraints are **NDP count (`max_ndp_sessions`), airtime fairness, and CPU** — not bandwidth. Per-peer goodput degrades non-linearly as peers/contention rise; your loaded-duplex p95 already climbed to 234 ms with just two phones. **[INF, matches brief prohibition]**
- **Asset scheduling:** run slides/map downloads on a **separate, lower-priority lane** with explicit pacing so they never starve audio/control; cap concurrent asset streams; use content-addressed chunks with resumable ranges. Handle **late joiners** via a "current presentation state" snapshot pushed on join, **partial/resumed transfers** via chunk manifests + range requests, and **group-wide state recovery** via a periodic signed "state beacon" (current slide/pin) so any guest can re-sync without the guide re-sending everything. **[INF]**

---

## 6. Recommended architecture

**Primary (D1):**
```
                 [GUIDE PHONE]
        BLE advert (room name, open) + control
        Wi-Fi Aware publisher (service = room)
                 |   |   |   ...            (per-peer NDP / paired conn)
     ------------+---+---+------------------------
     |           |               |               |
 [Guest A]   [Guest B]  ...  [Guest R = relay] ...
 (unicast)   (unicast)        |     |            (Android star, N<=ceiling)
                          [Guest R1][R2]  (bounded relay tree, overflow only)
```
- **Discovery/control plane:** BLE (open room metadata, admission, pointer/control, presentation state). Cross-platform, low power, works while moving.
- **Media/asset plane:** Wi-Fi Aware unicast fan-out (Android guide → Android guests) and paired-peer connections (iOS↔iOS). Encode once, replicate per peer.
- **Security plane:** open-room session key for AEAD media; P-256 sign-once on guide frames; session-pinned guide public key; optional SPAKE2 short-code lock.

**Fallback:** **Shared-LAN transport (your preserved baseline)** — the only currently-viable **mixed iOS/Android** high-bandwidth path, and the router-full mode. Also the safe path when Aware NDP ceiling/interop fails.

**Overflow behavior:** when the guide's available data paths (`getAvailableDataPathsCount()`) are exhausted, promote nearby guests to **bounded relays** (fixed fan-out, ≤1–2 hops, authenticated). Never unbounded mesh.

**Explicit unsupported cases (state to users/PM):**
- Router-free **mixed iOS+Android** live audio → not supported at launch.
- **iOS guests with locked phones** → audio drops (no Aware background).
- **Wi-Fi radio disabled** (BLE-only) → BLE L2CAP audio is a **degraded-quality/last-resort** lane. L2CAP connection-oriented channels ARE public APIs (iOS 11+, Android 10+), but throughput is low: Nordic measures BLE app-level throughput around 1.4 Mbps on the 2 Mbps High-Throughput feature, ~775 kbps on BLE 4.2, and Apple↔Apple `CBL2CAPChannel` transfers are frequently reported far lower (tens to low-hundreds of kbps because iOS-as-central won't let the app set connection parameters). Enough for compressed 16–20 kb/s speech, but with tight headroom and cross-platform quirks — treat as last resort. **[DOC]**
- **Auracast** to earbuds directly from the app → not available.

---

## 7. Capacity model (peers vs data paths vs sockets)

- **1 guest = 1 NDP** (Android) or **1 paired connection** (iOS). Multiple sockets to one guest multiplex over that **single** data path; separate sockets do **not** create radio-level QoS.
- **Data-path ceiling:** `max_ndp_sessions` (vendor firmware) → query at runtime; **treat as small and unknown**; your historical "8" is a device observation, not a guarantee. Design so the star degrades to relays well before the ceiling.
- **Bandwidth:** ~79 kbps/listener worst case (per-frame signing) → ~2.4 Mbps for 30; not the constraint.
- **Airtime:** shared; the real ceiling. Loaded p95 RTT already rose to 234 ms in your duplex trials with **two** phones — expect worse tails under N-way fan-out.
- **Packet rate:** 50 pkt/s/listener × N; watch per-socket send scheduling and delayed-ACK if any TCP remains.
- **Security overhead:** AEAD 16 B + P-256 64 B/sig dominate small frames; amortize signing.
- **Latency budget:** capture + 20 ms encode + jitter buffer (40–60 ms) + network (one-way ≤50 ms target) + decode/playout → mouth-to-ear p95 ≤150 ms goal.

---

## 8. Prioritized experiments

**E1 — Two Androids, real fan-out + AEAD/codec (not synthetic).**
- *Hypothesis:* full tour pipeline (mic→Opus→AEAD→sign→NDP→decode→speaker) sustains <150 ms mouth-to-ear at 20 kb/s over one NDP.
- *Setup:* two Pixels, Wi-Fi radios on, no AP association removed; production media lane, not synthetic blocks.
- *Instrumentation:* timestamped frames end-to-end; jitter-buffer occupancy; loss/PLC counters; p50/p95 mouth-to-ear via loopback-tone + mic capture with known reference.
- *Pass/fail:* p95 mouth-to-ear ≤150 ms; loss <1%; no audible dropouts over 10 min.
- *Unlocks:* baseline audio quality → proceed to scale.

**E2 — Latency-tail isolation (Q4).**
- *Hypothesis:* p95 tail is dominated by TCP delayed-ACK/loopback buffering, not radio.
- *Setup:* A/B UDP-vs-TCP media lane; toggle Nagle/quickack; bypass loopback adapter with native datagram path; log Aware availability-window events.
- *Instrumentation:* per-hop timestamps (app→socket→radio); pcap where possible.
- *Pass/fail:* identify the component contributing the 140+ ms spikes; UDP path p95 ≤80 ms one-way.
- *Unlocks:* transport decision (UDP + jitter buffer).

**E3 — NDP concurrency ceiling on real hardware.**
- *Hypothesis:* one guide phone sustains K simultaneous NDPs before `getAvailableDataPathsCount()` hits 0 / goodput collapses.
- *Setup:* incrementally add Android guests (5,10,15,20,25,30); log available resources, per-peer goodput, airtime, RTT p95.
- *Instrumentation:* `AwareResources`, per-peer throughput, CPU, battery drain.
- *Pass/fail:* find K where per-peer p95 RTT >150 ms or setup fails; if K<30, relay tree required.
- *Unlocks:* star-vs-relay decision and overflow threshold.

**E4 — iPhone + Android interop probe (time-boxed).**
- *Hypothesis:* Android (Aware Pairing v4.0 device) can pair AND complete an NDP with iOS 26.
- *Setup:* Aware-Pairing-capable Android + iPhone 12+/iOS 26 (latest); Apple sample service names.
- *Instrumentation:* pairing callbacks, NDP request/response logs, `NWError` capture (incl. any -11992 context — record, do not interpret).
- *Pass/fail:* bidirectional data path with real bytes. **Expected fail** given F5; box to ≤1 week.
- *Unlocks:* confirm/deny mixed router-free; if fail → LAN is the only mixed path (already the plan).

**E5 — Locked-phone & movement endurance.**
- *Hypothesis:* Android guest (mediaPlayback FGS) keeps audio locked and re-joins after 30 s out-of-range; iOS guest drops on lock.
- *Setup:* lock screens; walk out/in of range; toggle radios.
- *Instrumentation:* audio-continuity log; reconnection time; battery over 60–90 min.
- *Pass/fail:* Android locked-continuity ≥ target; reconnection <5 s; document iOS drop explicitly.
- *Unlocks:* field-readiness + user-facing constraints.

**E6 — Group scale + assets coexistence.**
- *Hypothesis:* slide/map downloads do not delay audio/control under N-way load.
- *Setup:* push assets to late joiners during live audio at scale from E3.
- *Instrumentation:* audio p95 with/without concurrent asset lane; resume/partial-download correctness.
- *Pass/fail:* audio p95 unchanged (<10% delta) with assets active; late joiner recovers full state.
- *Unlocks:* asset scheduler sign-off.

*(No experiment claims one round eliminates hardware-dependent failures; each is per-device-class.)*

---

## 9. Implementation sequence (preserve LAN baseline; separate coding from qualification)

1. **Keep LAN transport untouched** as baseline + mixed-platform fallback. (No regression.)
2. **Media transport: add native UDP datagram lane** replacing loopback-socket adaptation for the realtime lane (pending E2); keep bounded queues (8 frames), 150 ms drop, but retune ACK window for UDP. *(Coding.)*
3. **Signing integration:** wire sign-once into **every** guide media lane; add **session-lifetime public-key pinning** in the app; amortize signing cadence (Q7). *(Coding.)*
4. **Admission key delivery:** implement trustworthy guide-key delivery at admission (embed pinned key in BLE/Aware room metadata + optional OOB fingerprint). *(Coding — closes F12 gap.)*
5. **Overflow relay:** bounded, authenticated relay tree keyed off `getAvailableDataPathsCount()`. *(Coding.)*
6. **Optional lock:** replace raw short-code compare with **SPAKE2** PAKE. *(Coding — no custom crypto.)*
7. **Background/FGS:** Android FGS types (`microphone` foreground-start, `mediaPlayback`, relay type); iOS: accept no-background, design graceful drop/rejoin UX. *(Coding.)*
8. **Physical qualification:** run E1→E6 in order on real devices; gate each feature flag on its experiment's pass criteria. *(Qualification, separate from coding.)*

---

## 10. Stop conditions

- **Android↔iOS Aware (E4):** if pairing+NDP fails on current shipping OS/hardware after a ≤1-week box, **stop**; mixed-platform = LAN only. Do not repeatedly patch pairing.
- **NDP scale (E3):** if the guide phone cannot exceed a small K and relay trees don't lift effective fan-out to 30 with acceptable latency, **stop** pursuing router-free Aware for large groups; require shared LAN for 30-person tours.
- **Latency (E2):** if no transport/config gets mouth-to-ear p95 under 150 ms, **stop** promising "live" audio; reposition as near-live with larger buffer.
- **iOS locked (E5):** if no supported background path keeps iOS guests listening while locked, **stop** trying; document as a fixed platform limitation, add a "keep screen on" UX.
- **Auracast/LE Audio:** already blocked by F6; **do not** invest until Android/Apple expose third-party broadcast transmit AND phone-app receive.
- **General:** never move to rooted/jailbroken devices or private APIs to bypass any of the above.

---

## 11. Remaining questions (architecture-changing only)

- **R-Q1:** What is the actual `max_ndp_sessions` / `getAvailableDataPathsCount()` on your target Android device classes? (Decides star vs relay; resolved by E3.)
- **R-Q2:** Does any current Aware-Pairing-capable Android complete an NDP with iOS 26.4? (Decides whether router-free mixed is ever viable; E4.)
- **R-Q3:** Root cause of the p95 tail — transport vs radio vs loopback? (Decides transport rewrite scope; E2.)
- **R-Q4:** Can iOS guests stay connected while locked under any supported mode, or is a "screen-on" UX mandatory? (Decides iOS field UX; E5.)
- **R-Q5:** Meaning/trigger of `NWError.wifiAware(-11992)` — still unknown; needs Apple DTS/Feedback confirmation before relying on iOS publisher robustness.

---

## 12. Sources (primary)

- Android Developers — Wi-Fi Aware overview (updated 2026-08-14): `developer.android.com/develop/connectivity/wifi/wifi-aware`
- AOSP — Wi-Fi Aware (source.android.com/docs/core/connect/wifi-aware); Wi-Fi HAL interface combinations; `hardware/libhardware_legacy/.../wifi_nan.h` (`NanCapabilities.max_ndp_sessions`, verbatim on googlesource)
- Android reference — `AwareResources.getAvailableDataPathsCount()` (API 31), `Characteristics.getNumberOfSupportedDataPaths()` (API 33), `getAvailableAwareResources()`
- Android — Foreground service types required (Android 14) and restrictions on background FGS start
- Apple — WiFiAware framework docs; Connecting-paired-devices; `com.apple.developer.wifi-aware` entitlement; WWDC 2025 Session 228
- Apple Developer Forums — 790195 / 796446 (iOS↔Android interop, NDP failures), 791628 (pairing mandatory), 791898 (-11992 observed), 787570 (no Aware background), 804414 (DeviceDiscoveryUI/Aware), 89644/774300/723218 (L2CAP throughput), multicast-entitlement threads
- Espressif — "Connect ESP with an iPhone using Wi-Fi Aware" (2026-08): iPhone 12+, iOS 26, mandatory 6-digit PIN, concurrent interface
- Bluetooth SIG — Auracast/LE Audio; Android LE Audio docs; dev.to broadcast-assistant writeup (BASS restricted since Android 13)
- Nordic Semiconductor / Memfault-Interrupt (2019) — BLE throughput (~1.4 Mbps 2M PHY; ~775 kbps BLE 4.2; ~0.381 Mbps BT 4.0 LL)
- IETF — RFC 9382 SPAKE2 (Sept 2023), RFC 9383 SPAKE2+, RFC 4082 TESLA, RFC 9119 (multicast over 802.11), RFC 896 (Nagle), RFC 1122 (delayed ACK), Opus RFC 6716/7587, RFC 6363 FEC
- Stuart Cheshire — "TCP Performance problems caused by interaction between Nagle's Algorithm and Delayed ACK"
- ITU-T G.114 (05/2003) one-way transmission time (<150 ms transparent; >400 ms unacceptable)
- US patents on NAN multicast (10,271,180) confirming unicast-only shipping NDP model
- Your lab: commit 7dca55f (2026-09-07) benchmark table and fixtures

---

## Direct answer

**Can this product deliver one guide's live audio to 30 mixed phones outdoors without an access point?**

**Partially — and not for mixed platforms today.** For an **all-Android** group it is achievable now via **replicated unicast over per-peer Wi-Fi Aware data paths**, with **BLE for open-room discovery/control**, app-layer AEAD + P-256 sign-once for security, and a **bounded authenticated relay tree** once the guide phone's data-path ceiling is reached. For **iOS**, the same works **iOS-to-iOS** (paired peers, iOS 26+), but **iOS guests cannot listen while locked** and **Android↔iOS Wi-Fi Aware interop is not established** (mandatory Apple pairing + reported NDP-completion failures). There is **no public broadcast primitive** — not Wi-Fi Aware multicast, not IP multicast without an AP, not LE Audio/Auracast from a phone app — that lets you "send one packet and have 30 unpaired phones receive it." **Mixed iOS+Android at 30 people is only reliable today over your preserved shared-LAN transport.**

**Exact publicly-supported mechanism:** BLE discovery/control + Wi-Fi Aware **unicast fan-out / paired-peer** media (per-platform), with shared-LAN multicast as the mixed-platform fallback.

**Limitations:** unknown NDP concurrency ceiling; shared-airtime degradation under N-way load; iOS no-background/locked drop; no cross-platform router-free path; BLE-only (Wi-Fi radio off) is degraded audio at best; guide-key trust delivery still unbuilt; no per-member revocation.

**Evidence still missing (gating):** real NDP ceiling on target devices (E3); latency-tail root cause and UDP p95 (E2); full-pipeline mouth-to-ear quality (E1); iOS-locked behavior (E5); and a definitive Android↔iOS interop result (E4). None of these is proven by a two-phone speed test, a simulator, a decoded-tone fixture, or a share-sheet transfer.
