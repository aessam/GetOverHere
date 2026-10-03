# Deep code review — September 22, 2026

Branch `fix/deep-dive-2026-09-02` at `b820aaf`. Review only: no production code changed, nothing committed.
Scope: whole codebase (~40K production lines Swift/Kotlin). Excludes the repaired
gateway findings F1–F12 (`SecurityCodeReview-2026-09-15.md`) unless a repair is shown broken.
FND-1 is a consequence of the F1 encoder-replacement repair.

Method: six parallel lanes (sealing, parity, admission, concurrency, errors/privacy,
assets/audio), then an adversarial red-team pass that re-read every cited line.
Severities below are post-red-team. Tags: **Reproduced** = executed (scratch program,
model against the real buffer class, or the real CLIs); **Source-confirmed** = traced,
not executed; **Unverified** = needs a device. Retained repro sources, gate logs and exact
commands: [`benchmarks/2026-09-22-code-review/README.md`](benchmarks/2026-09-22-code-review/README.md).

Severity: **P1** fix before the next physical session; **P2** real defect with a concrete
failure path, fix before field acceptance; **P3** hygiene, parity, narrow or unverified.

## Software gate

`scripts/verify_tour_session.sh`: steps 1–8 pass. Step 9 failed on environment only:
the default destination `iPhone 17 Pro` simulator is not installed (exit 70). Step 9
rerun with the script's exact command and `iPhone 17 Pro Max` (iOS 27.0):
**Passed, 248 passed / 0 failed / 4 skipped.** The script's default destination should
be updated or made to fail with a clearer preflight message.

## Verdict

**Fix FND-1 before the next physical session.** It silently mutes every guest after an
Android guide encoder recovery and is reproducible in software, so a device session would
be spent rediscovering it. The suite passes because no test drives guest playback across
a sender stream change or long-duration clock drift.

## P1

**FND-1 Android guide encoder replacement mutes all guests for roughly the elapsed tour time.** Reproduced (model with the real Swift-core `EncodedAudioJitterBuffer`; Kotlin buffer source-traced to the same rule), red-team confirmed.
`Android/.../core/UDPAudioPlane.kt:82-84,201-217,299,306`: `retireEncoder` (2s stall or encoder exception) creates a new `BroadcastCodecState`, new streamID, sequence restarts at 0.
Guests rebuild `PlayoutClock` only on codec config change (`UDPAudioPlane.kt:733`, `UDPAudioPlane.swift:693`); the jitter buffer rejects `sequence < expected` as duplicate (`RealtimeAudioBuffer.kt:85-87`), and `expected` stays frozen while empty. Model: 90,000 frames then restart at 0 → next 3,000 frames all rejected. No error surfaces.
iOS guides are unaffected: replacement assigns `state.encoder` on the existing `BroadcastCodecState`, keeping streamID and sequence (`UDPAudioPlane.swift:185-200`).
Fix direction: reset guest playout on sender stream change (detect before open, since the opened envelope drops streamID), or keep sequence continuity across Android replacement. Add a guest-playback regression, not just a sender-output test (`RealtimeCaptureInboxTest.kt:31` checks only the sender).

## P2

**FND-2 Jitter-buffer clock-offset baseline never re-anchors.** Reproduced (model), severity lowered from P1.
`RealtimeAudioBuffer.swift:169-170`, `.kt:151-153`: `minimumClockOffsetNanoseconds` only decreases; reset only on codec config change; frame lifetime 500ms (`UDPAudioPlane.swift:298`, `.kt:428`). If the guest clock runs fast relative to the guide, every frame eventually expires: model over 4 h shows +100ppm → permanent silence from 76.7 min, +40ppm → 191.7 min, −40ppm → never (ppm values assumed, not measured). Reconnect clears it, but nothing triggers a reconnect because no `.failed` event fires. The "iOS guide sleeps 1s" variant is not credible (audio background mode).

**FND-3 Guide's shared inbound opener grows without bound and updates replay state before the sender check.** Source-confirmed; Swift core mechanism reproduced.
`LocalSessionControlTransport.swift:116,208-212`, `WiFiAwareSessionLaneTransport.swift:96,140`, `LocalSessionControlTransport.kt:125,397`; windows in `EncryptedSessionProtocol.swift:285-304,364-380` / `.kt:255,307`.
(a) Windows keyed by (session, sender, stream) are never pruned; honest reconnects accumulate, and an admitted guest sending each frame on a fresh streamID grows guide memory unbounded.
(b) Replay window advances before `senderID == participantID`; a guest who has sniffed guest B's IDs can jump B's floor and get B disconnected (targeted variant is P3: needs capture of random 128-bit IDs).
Fix direction: one opener per connection, or validate sender/stream before `open()`. Fixes both.

**FND-4 Self-asserted participant IDs let any admitted guest fill all 30 slots.** Source-confirmed.
`LocalSessionControlTransport.swift:535-548`, `.kt:446`, `UDPAudioPlane.swift/.kt:899`. The hello proof is keyed only by the shared media credential; any guest can mint IDs until `SessionParticipantSlots` returns `.full`. Open rooms admit anyone. Same-ID eviction/impersonation of a specific guest needs sniffing (P3).

**FND-5 Android sequence allocation races the sealer lock.** Source-confirmed.
`LocalSessionControlTransport.kt:306,317`: `sequence.getAndIncrement()` outside `@Synchronized seal`; the sealer requires strictly increasing sequences (`EncryptedSessionProtocol.kt:201-204`). Concurrent callers exist: `PresentationService.kt:371-386` (socket thread, guest join replay) vs `publish`/`setTarget` (`:195,:206,:222,:337,:346`); `TourAssetTransferService.kt:218` vs `:379`. A slide change during a guest join can fail with identity reuse and be missed by all guests. Narrow window. Swift unaffected (MainActor).

**FND-6 Locked room codes have no online guessing limit.** Source-confirmed.
`RoomAdmissionTransport.swift:98-128`, `.kt:52-80`: no failure counter, backoff, lockout or guide signal; codes can be 4 chars (`RoomAdmission.swift:23`). The attacker pays 600k PBKDF2 per guess (salt includes session ID, so no pre-session precompute), which is cheap on a GPU for short human codes during a live tour. ADR-052 documents only the offline rogue-guide case.

**FND-7 iOS socket closed without shutdown while a reader may be in raw-fd `recv`.** Source-confirmed.
`SocketFrameIO.swift:236-238` (drain failure → `fail()` → `close()`), reader at `LocalSessionControlTransport.swift:899-916`, `UDPAudioPlane.swift:507`. After close, the kernel can reuse the fd number for the next accepted guest; the stale reader then consumes that guest's handshake. `stop()` is safe (shutdown precedes close). Narrow window; impact is failed joins under churn, not data exposure (AEAD).

**FND-8 iOS guide capture consumed on the main actor with a one-buffer backlog.** Source-confirmed.
`AudioEngine.swift:172` `.bufferingNewest(1)`, consumer `ChannelService.swift:826-830` inherits MainActor, ~100ms buffers. A main-thread stall >100ms (see FND-9) drops guide speech for every guest.

**FND-9 iOS asset cache does file IO and hashing on the main thread.** Reproduced (model under project flags).
`TourAssetCache.swift:44` has no isolation annotation; target default is MainActor (`project.pbxproj:455`). `queue.sync` (`:58-83`), fsync per 60 KiB chunk (`:126`), full SHA-256 at completion (`:177`). Feeds FND-8 and FND-10.

**FND-10 iOS guest playback latency only grows.** Source-confirmed.
`ChannelService.swift:1192-1195` spawns a Task per 20ms frame; `AudioEngine.swift:136-139` calls `scheduleBuffer` with no depth limit. After any main-thread stall the backlog plays back-to-back and the added latency is permanent. Android is bounded (`AudioTrack` non-blocking).

**FND-11 Offline map style validation is a denylist.** Parse Reproduced; network fetch not proven.
`OfflineMapPack.swift:75-93,169-175`, `OfflineMapPack.kt:58-83,142-147` reject only `http(s)://` prefixes on four keys. Accepted: GeoJSON `data: "https://…"`, `pmtiles://https://…`, array-form `sprite`, protocol-relative `//host`. A guide-supplied style can make guest MapLibre contact third-party hosts, breaking the no-internet boundary. Fix: allowlist local schemes for every URL-bearing value.

**FND-12 iOS privacy manifest omits a required-reason API.** Source-confirmed.
`UDPAudioPlane.swift:1084` uses `ProcessInfo.systemUptime` (System Boot Time category); `PrivacyInfo.xcprivacy` has empty `NSPrivacyAccessedAPITypes`. App Store upload flags ITMS-91053. Declare `NSPrivacyAccessedAPICategorySystemBootTime` / `35F9.1`. (The function is also misnamed `wallClockNanoseconds`.)

**FND-13 Guest asset cache has no size cap, no eviction, and is in iOS backup.** Source-confirmed.
`byteLength` is UInt64 with no pack-size or free-space check; nothing prunes `AssetCache/complete|partial`; iOS cache lives in Application Support without `isExcludedFromBackup` (`AppCoordinator.swift:31-33`). An open-room (unverified) guide can declare a huge asset and fill guest disk; past-tour content persists and goes to iCloud backup. Android has `allowBackup=false`.

## P3

| ID | Finding | Location |
|---|---|---|
| FND-14 | Swift `String(data:encoding:.utf8)` strips a leading U+FEFF; Kotlin keeps it. Breaks exact-value parity; an Android guest with a BOM-prefixed display name fails the HMAC against an iOS guide. Reproduced via both CLIs. | `SessionProtocol.swift:470`, `BluetoothRoomRecord.swift:41`, `GatewayProtocol.swift:115` vs `SessionProtocol.kt:376-380` |
| FND-15 | Asset UInt64 fields ≥2^63: Swift accepts, Kotlin fails with bare `IllegalArgumentException`. Credential holder only. Reproduced. | `AssetPayloads.swift:229,262,300` vs `AssetPayloads.kt:32,140,234,274,315` |
| FND-16 | Replay-window math is unsigned in Swift, signed in Kotlin; diverges for sequences ≥2^63. Not red-team checked. | `EncryptedSessionProtocol.swift:241,324,365,384-387` / `.kt:203,267,308,326-327` |
| FND-17 | Gateway host control-character class differs (Cc+Cf vs Cc). | `GatewayProtocol.swift:51` / `.kt:61` |
| FND-18 | No cross-platform rejection fixtures for GOH2 envelopes/payloads (trailing bytes, BOM, ≥2^63, bad bools); TourAssetKind 3/4/5 unfixtured. FND-14/15 live in this gap. | `scripts/verify_*` |
| FND-19 | Verifier `if rg …; then fail` treats rg exit 2 (missing rg or renamed path) as pass; no `rg` preflight. The payload privacy scan covers only the core packages and a narrow regex. | `verify_tour_session.sh:240-262` |
| FND-20 | Admission slots (8) + 5s deadline, no per-source limit: LAN host can block admission. | `RoomAdmissionTransport.swift:98` / `.kt:57` |
| FND-21 | Guest opener recreated per join while guide streamID is stable: on-path replay of older guide frames after reconnect. Snapshot-version mitigation unverified. | `LocalSessionControlTransport.swift:268` |
| FND-22 | Android bridge binds fixed loopback ports; another app can squat them or reach the forwarded lanes. | `NearbySocketBridge.kt:122-124` |
| FND-23 | Audio client removal keyed by (fd, per-run generation), unlike control lane's socket-object key. | `UDPAudioPlane.swift:812-815` vs `LocalSessionControlTransport.swift:551` |
| FND-24 | `startForegroundService` re-issued on every gateway status emission, scope has no exception handler; may crash if Android rejects a background restart. **Unverified**: needs device test. | `ComeOverHereApp.kt:26,52-62`, `TourAudioForegroundService.kt:53,109` |
| FND-25 | Thread-per-connection plus `DispatchSemaphore` waits on the main actor (~180 threads at 30 guests). Not measured. | `LocalSessionControlTransport.swift:198,285,379`, `UDPAudioPlane.swift:493,576` |
| FND-26 | Guide content-store failure silently shown as "no map". | `ChannelService.swift:954`, `ChannelService.kt:1031` |
| FND-27 | Bare `?: return` in control `Failed` handler: no log, no state change. | `ChannelService.kt:1368-1372` |
| FND-28 | Writer `catch (_: Exception)` drops the failure cause. | `BoundedSocketFrameWriter.kt:137` |
| FND-29 | `try?` decode chain loses cause; dead RAFT `heartbeat`/`vote` and `wifiCredentials` (SSID/password) cases still decoded after ADR-050. `BLEControlPlane` (Swift/Kotlin) is compiled with zero references. | `TransportProtocol.swift:137-140,184-198` |
| FND-30 | iOS guest: codec setup/parse/open errors after auth end the tour instead of retrying; no negotiated-codec check. Decode errors do retry. | `UDPAudioPlane.swift:720-727` |
| FND-31 | iOS guide has no inbound asset-event caps (Android: 8 KiB / 90 events). | `TourAssetTransferService.swift:124-130` vs `.kt:96-104` |
| FND-32 | Realtime lane accepts 1 MiB frames and allocates before AEAD; real frames ~150 B. | `UDPAudioPlane.swift:297` |
| FND-33 | Nonce = HMAC(applicationKey, identity) with the same key used for AES-GCM; no key separation. Hygiene, no known attack; wire change. | `EncryptedSessionProtocol.swift:439-450` |
| FND-34 | Signed guide frames cap at 64 KiB vs 1 MiB control lane; large manifests fail `sign()` with no authoring check. | `SignedGuideFrame.swift:11` |

## Cleared

- Seal-once invariant holds: one sealed frame fans out; no writer, bridge, retransmit or asset-resume path seals or allocates nonces. Nonces unique across restarts/lanes/routes; AAD covers the full 70-byte header.
- GOS1 signature and low-S checked before decode/AEAD on all guest paths; guide pin enforced on all three lanes and survives same-session rejoin.
- No admission v1 path between native apps; transcript and hello are fresh; credential rotates per tour; constant-time proof compares.
- `NearbySocketBridge` connects only to loopback lane ports from a closed enum.
- Wire parity: header/field order, endianness, UUID bytes, enum raw values, trailing-byte rules, PBKDF2/HKDF/AES-GCM/GOS1 match across all codecs.
- Asset lane bounds: chunk offset/length checks, offset == partial length, whole-file SHA-256 before ready, 60 KiB on both sides, hash-only paths (no traversal), bounded scheduling.
- No secret logging, participant location stays local, guests cannot transmit audio, no analytics/Nearby/HTTP clients, debug controls gated, Android runtime owned by `ComeOverHereApp`, all Aware APIs behind `@available(iOS 26.4, *)`.

## Suggested order

1. FND-1 (+ guest playback regression), FND-2: audio correctness on long tours.
2. FND-3/FND-4/FND-5: per-connection opener, participant slot policy, Android sequence under lock.
3. FND-8/9/10: take capture, asset cache and playback scheduling off the main actor.
4. FND-11/12/13: boundary and store-submission issues.
5. FND-18/19: close the verifier gaps that let FND-14/15 through.
