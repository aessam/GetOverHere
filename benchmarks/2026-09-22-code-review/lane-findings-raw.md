## L4 concurrency
- L4-1 P2 SC: SocketFrameIO.swift:28-49 ManagedSocket.cancel() shutdown outside lock; close on drain thread races; readers loop on raw fd (LocalSessionControlTransport.swift:204,399; UDPAudioPlane.swift:507) -> fd reuse hits new guest handshake. Fix: single closer / shutdown+close under lock.
- L4-2 P3 SC: UDPAudioPlane.swift:812-815 removeClient(fd:generation:) generation per run not per conn; stale removal after fd reuse removes wrong guest. Key by ManagedSocket like control lane (:551).
- L4-3 P2 SC: AudioEngine.swift:172 bufferingNewest(1) consumed on MainActor (ChannelService.swift:826-830); >100ms main stall drops guide audio for all.
- L4-4 P2 PLAUSIBLE: ComeOverHereApp.kt:52-62 combine(listenState,gateway.status) re-calls startForegroundService (TourAudioForegroundService.kt:109) unguarded in SupervisorJob+Main without handler; background FGS start / MICROPHONE type SecurityException -> crash ends tour. Add distinctUntilChanged + handle.
- L4-5 P3 SC: thread-per-connection + DispatchSemaphore waits on main actor (LocalSessionControlTransport.swift:198/285/379, UDPAudioPlane.swift:493/576); ~180 threads at 30 guests.
Cleared: Android runtime ownership in ComeOverHereApp; no GlobalScope; bounded writer queues; generation-gated emits; locked @unchecked Sendable.
## L5 errors/privacy
- L5-1 P2 REPRO(iOS parse): OfflineMapPack.swift:75-93,169-175 / OfflineMapPack.kt:58-83,142-147 rejectRemoteResource denylist only http(s):// prefix on glyphs/sprite(string)/sources.url/tiles. Accepted: geojson data https, pmtiles://https, sprite array, //protocol-relative. Guide-supplied style -> guests fetch internet (IP leak, breaks no-internet boundary). MapLibre fetch not proven. Fix: allowlist.
- L5-2 P2 SC: UDPAudioPlane.swift:1084 ProcessInfo.systemUptime; PrivacyInfo.xcprivacy empty NSPrivacyAccessedAPITypes -> ITMS-91053 (SystemBootTime 35F9.1). Also misnamed wallClockNanoseconds.
- L5-3 P3 SC: ChannelService.swift:954 try? manifestPayload / ChannelService.kt:1031 runCatching.getOrNull -> storage fault shown as "no map".
- L5-4 P3 SC: ChannelService.kt:1368-1372 Failed handler bare ?: return (no log/state).
- L5-5 P3 SC: BoundedSocketFrameWriter.kt:137 catch(_) false drops cause.
- L5-6 P3 SC: TransportProtocol.swift:184-198 try? chain loses cause; dead RAFT heartbeat/vote + wifiCredentials(SSID/password) cases still decoded.
- L5-7 P3 SC: verify_tour_session.sh:234-246 privacy scan only cores, misses app wire types BLECommand/ChannelAnnounce.
Cleared: no secret logging; location local; guests can't transmit; no analytics/Nearby; debug gated; manifest ok.
## Gate
verify_tour_session.sh steps 1-8 PASS; step 9 failed env: iPhone 17 Pro sim not installed (EXIT=70). Rerun step 9 on iPhone 17 Pro Max iOS 27.0: Passed, 248 passed / 0 failed / 4 skipped.
## L3 admission
- L3-1 P2 SC: RoomAdmissionTransport.swift:98-128/.kt:52-80 no rate limit/lockout on wrong room code; 8 concurrent; codes >=4 chars (RoomAdmission.swift:23); PBKDF2 salt = public sessionID -> precompute; online guessing from LAN. ADR-052 only covers offline by rogue guide.
- L3-2 P2 SC: LocalSessionControlTransport.swift:544-546/.kt:446, UDPAudioPlane.swift/.kt:899 hello proof only shared credential; participantID self-asserted; registerClient evicts same ID; senderID plaintext in header -> admitted guest evicts/impersonates others or fills 30 slots.
- L3-3 P2 SC: guide inboundOpener shared per start (LocalSessionControlTransport.swift:116/.kt:125); SessionFrameOpener.streamWindows (EncryptedSessionProtocol.swift ~304/.kt:255) never pruned; up to 4096 entries/window; new streamID per frame -> unbounded guide memory.
- L3-4 P3 SC: 8 admission slots + 5s deadline, no per-source limit -> LAN DoS of admission.
- L3-5 P3 SC: guest opener recreated per startGuest (:268), guide streamID stable -> on-path replay of older guide frames on reconnect; snapshot versioning mitigation unverified.
- L3-6 P3 SC: NearbySocketBridge.kt:122-124 fixed loopback ports reachable by other Android apps; squatting -> join fails.
Cleared: no v1 downgrade; pin on all 3 lanes; pin survives rejoin; transcript fresh; hello replay fails; credential rotates; bridge not a proxy; single-route lease; UInt64 seq.
## L1 sealing
- L1-1 P2 REPRO(Swift core): shared guide inbound opener (LocalSessionControlTransport.swift:116,:208; WiFiAwareSessionLaneTransport.swift:96,:140; .kt:125,:397) updates replay window before senderID==participantID check; guest A forges B's sender/stream, jumps floor -> B rejected/disconnected. Also pre-fill -> identityReuse. Fix: per-connection opener or check before open(). (merges with L3-3, L1-3)
- L1-2 P2 SC: LocalSessionControlTransport.kt:306/:317 sequence.getAndIncrement outside @Synchronized seal -> concurrent sends (PresentationService.kt:371-386 vs :206/:222/:346; TourAssetTransferService.kt:218 vs :379) -> identityReuse, authoritative slide frame dropped. Swift unaffected (MainActor).
- L1-3 P3 = L3-3 (unbounded streamWindows).
- L1-4 P3 = L3-5 (replay after guest reconnect).
- L1-5 P3 SC: EncryptedSessionProtocol.swift:439-450 nonce=HMAC(applicationKey,...) same key as AES-GCM; no key separation.
- L1-6 P3 SC: signed guide frame 64KiB cap vs 1MiB control lane; manifest >~680 assets fails sign() with no authoring check.
Cleared: seal-once fanout; no writer seals; no re-seal on retransmit/resume; nonce uniqueness; AAD full header; GOS1 verify-first; constant-time compares; parity; admission random nonces.
Note: all guests share one app key -> guest can read other guests' uplink if captured (by design? undocumented).
## L2 parity
- L2-a P2 REPRO(CLIs): SessionProtocol.swift:470 (also BluetoothRoomRecord.swift:41, GatewayProtocol.swift:115) String(data:encoding:.utf8) strips leading U+FEFF; Kotlin SessionProtocol.kt:376-380 keeps it. slide efbbbf67617465 -> Swift "gate" vs Kotlin BOM+gate. Android guest with BOM displayName can't auth to iOS guide (HMAC over stripped name, LocalSessionControlTransport.swift:183,699; UDPAudioPlane.swift:890); manifest duplicateSlideID on iOS only.
- L2-b P2 REPRO(CLIs): AssetPayloads.swift:229,262,300 accept UInt64>=2^63; AssetPayloads.kt:32,140,234,274,315 require(>=0) -> bare IllegalArgumentException. Divergent rejection.
- L2-P3a: replay window unsigned Swift vs signed Kotlin (EncryptedSessionProtocol.swift:241,324,365,384-387 / .kt:203,267,308,326-327) seq>=2^63 diverges; credential holder only.
- L2-P3b: GatewayProtocol.swift:50 controlCharacters (Cc+Cf) vs .kt:61 isISOControl (Cc).
- L2-P3c: no cross-platform rejection fixtures (only verify_gateway_protocol.py:86); TourAssetKind 3/4/5 unfixtured.
- L2-P3d: verify_tour_session.sh:243-324 `if rg ...` treats rg exit 2 (missing/renamed) as pass, no rg preflight; privacy regex narrow + core-only.
Cleared: header/field order/endianness/UUID all codecs; enum raw values; trailing bytes; AAD/nonce/PBKDF2/HKDF/GOS1 parity; code normalization.
## L6 assets/audio
- L6-P1-1 REPRO(model w/ real EncodedAudioJitterBuffer): Android guide retireEncoder (UDPAudioPlane.kt:82-83,:201-217) new BroadcastCodecState -> new streamID, sequence restarts 0; guests don't check streamID, feed seq into existing PlayoutClock (UDPAudioPlane.swift:710, .kt:737), rebuilt only on codec config change; jitter buffer rejects seq<expected as duplicate (RealtimeAudioBuffer.swift offer, RealtimeAudioBuffer.kt:85-87) -> silence ~ equal to elapsed tour time. iOS guide keeps codec state (unaffected).
- L6-P1-2 REPRO(model): RealtimeAudioBuffer.swift localDeadline / .kt:151 minimumClockOffsetNanoseconds monotone-down, never reset except codec config change; 500ms lifetime (UDPAudioPlane.swift:298,.kt:428). Guest clock +100ppm -> permanent expiry at 83 min; +40ppm 208 min; iOS guide systemUptime pause during sleep 1s -> immediate permanent silence. ppm assumed.
- L6-P2-1 REPRO(model flags): TourAssetCache.swift:44 FileTourAssetCache MainActor by default isolation; queue.sync + fsync per chunk + full SHA-256 on main.
- L6-P2-2 SC: ChannelService.swift:1191-1194 Task per PCM frame -> AudioEngine.swift:136-139 scheduleBuffer unbounded; stall latency accumulates permanently on iOS guest.
- L6-P2-3 SC: UDPAudioPlane.swift:720-727 post-auth catch-all -> .authenticationFailed -> failGuestSession (ChannelService.swift:1267-1268,:1293); decoder/codec errors end tour; Android retries 5x (.kt:763). No negotiated-codec check.
- L6-P2-4 SC: no asset size/disk cap, no eviction of AssetCache complete/partial; iOS cache in Application Support not excluded from backup (AppCoordinator.swift:31-33).
- L6-P3-1 SC: iOS guide no inbound asset event caps (TourAssetTransferService.swift:124-130) vs Android 8KiB/90 (kt:96-104).
- L6-P3-2 SC: guest realtime accepts 1MiB frames (UDPAudioPlane.swift:297), alloc before AEAD.
Cleared: chunk bounds, offset==partial length, full-file SHA before ready, 60KiB both, no path traversal, bounded scheduling, drop-oldest writer, PCM16 LE, interruptions, audio focus.
