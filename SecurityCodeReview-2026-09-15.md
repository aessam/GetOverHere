# Two-hub gateway security and code review

## Repair disposition — September 15, after user approval

The original review below remains historical evidence against `ec1b0b8`.
F1–F12 have now been repaired. The software candidate passes the nine repository
gates, isolated original regressions, native Android emulator faults, actual
Mac↔Android TLS, setup UI and Release debugger exclusion. This is **software
verification, not field readiness or a claim of vulnerability-free code**.
Commands, counts, retained logs and build hashes:
[`benchmarks/2026-09-15-security-review/README.md`](benchmarks/2026-09-15-security-review/README.md).

| Finding | Repair and executed evidence |
|---|---|
| F1 | Terminal exceptions or two seconds without output retire the encoder; at most three replacements per codec per tour. Capture expiry alone does not reset it. Signed/AEAD output resumes on a fresh stream; original cold-start regressions and explicit exhaustion/cleanup tests pass. Fault providers test ownership, not real thermal reclamation. |
| F2 | Companion-only ±30s offer-clock allowance; issuer response validation stays strict. Local ceremony durations are monotonic and bounded at 120s. Mirrored boundary/rejection tests and native coordinator tests pass; no wire bytes changed. |
| F3 | Selected Apple connector captures its endpoint independently; scan pause retains the bounded room snapshot. A real local native metadata connection succeeds after pause. |
| F4 | Stored certificate validity checked; expired pin renewal allowed only when starting a new two-way enrollment. Existing confirmed transports do not rotate. Isolated Keychain persistence/renewal and AndroidKeyStore renewal tests pass; expired peers still fail TLS. |
| F5 | Shared bootstrap/per-lane budget acquired before acceptance callback/ACK. Rejection socket remains writable for capacity byte 2. Saturation and actual socket tests pass. |
| F6 | Gateway-only reliable write deadline, with explicit timeout reporting and closure; ordinary nearby/LAN baseline is not given the new timeout. Swift and Kotlin gateway policy aligned. Blocked-write tests, unaffected-owner budgets and byte/hash/asset-resume tests pass. |
| F7 | iOS exposes exhausted USB recovery and explicit retry in both roles. Deliberate retry resets budget without discarding enrollment. Controlled-sleep coordinator exhaustion/retry and native confirmed-reconnect tests pass. |
| F8 | Current failed accept owner is closed and cleared; native monitor rebinds the same interface. Injected accept failure followed by actual emulator TLS reconnection passes. |
| F9 | Room candidate index selects a surviving advertiser; both removal orders tested. Guide metadata matching does not replace admission/signature verification. |
| F10 | Android native recovery emits connecting/waiting/exhausted state; in-flight Connect is idempotent. Coordinator has no competing native retry loop. Native-owned state/UI boundary regression passes. |
| F11 | Absolute five-second open and incoming TLS/header/acceptance deadlines close blocked sockets, including pending local connect. Actual TLS peer sending incremental header bytes is closed within the test's 4–7s window; legitimate enrollment succeeds afterward. Not a claim that every malicious TLS stack was fuzzed. |
| F12 | Local socket ownership spans connect, acceptance write and forwarding. Injected acceptance failure releases proxy sockets/budgets; no pre-forwarding gap remains in the transport's cleanup scope. |

No physical devices were queried, installed, or changed. FieldAcceptance A13–A20
remains NOT RUN. The first broad simulator launch omitted the repository's serial
setting and stalled with failures; its log was retained. The first serial run
identified a pre-skew companion-expiry assertion; it was changed to test beyond
the bounded allowance. The final serial gate passed, not merely a retry of an
unexplained failure.

## Original review (before repairs)

Reviewed September15,2026 at `ec1b0b8` on `fix/deep-dive-2026-09-02`.
Scope: the two-hub implementation and its adjacent capture, discovery, TLS,
admission, forwarding, recovery and debug boundaries. The pasted review is input,
not independent proof. No physical devices were queried or changed. No production
fixes, dependencies or app configuration were changed during this review.

## Verdict

**NO-GO for declaring coding complete or promoting this gateway to field-ready.**
The earlier software suite passes despite real missing failure recovery. Four
new isolated tests fail against production code: two Android encoder cases and
the same skewed-clock offer in both Swift and Kotlin. Existing test counts were
real, but insufficient evidence for the earlier completion claim.

All identified fixes and their deterministic/component/UI regressions can be
implemented without phones. Actual USB/radio interoperability, locked speech,
acoustic latency, battery, outdoor recovery and audience capacity still require
the physical matrix. Simulated listeners do not establish radio group size.

## Findings: retain the supplied review's numbering

P1 means fix before gateway acceptance; P2 means a real narrower/conditional
defect or lifecycle gap. `Reproduced` means executed against existing production
code. `Source-confirmed` means the branch is present and traced, not that a
physical failure or exploit was executed.

### F1 — P1, reproduced: no terminal encoder/stall recovery

`Android/app/src/main/java/com/aessam/comeoverhere/core/UDPAudioPlane.kt:205,224,270`.
The capture owner preserves its encoder after every caught exception and after
eight accepted inputs without output. Later submissions cannot replace that
state. `encoderResetCount` and `lastEncoderResetReason` have no recovery writes.
Two review tests submit24 times over6s of injected monotonic time; neither a
permanently throwing encoder nor an accepted-but-never-output encoder is replaced.
The tests fail on the actual factory creation count, not only the dead reset
counter. The injected provider models failure; it does not claim native thermal
or MediaCodec behavior was exercised.

Required correction: distinguish ordinary delayed output from terminal failure
and a bounded no-progress stall. Preserve warm encoders across normal expiry;
implement bounded, observable replacement and a terminal actionable failure if
replacement also fails. Preserve sequence/nonce uniqueness when replacing state.
Require post-recovery signed output, accurate counters, and continued normal cold
startup tests. This could cause silence now, but is not proof of the cause of the
earlier physical Waiting for Audio observation. Android documents distinct
recoverable/transient codec failure behavior in its
[CodecException contract](https://developer.android.com/reference/android/media/MediaCodec.CodecException).

### F2 — P1, reproduced on both cores: fresh QR rejected by clock skew

`Packages/TourSessionCore/Sources/TourSessionCore/GatewayProtocol.swift:66` and
`Android/tour-session-core/src/main/kotlin/com/aessam/toursession/GatewayProtocol.kt:37`.
An offer made at1,000,000 expires at1,120,000. Scan after3s with a companion clock
10s behind: its now is993,000; remaining127,000 exceeds the permitted120,000.
Both actual validators reject it. Timers in both coordinators also use the remote
absolute expiry, so a core-only tolerance patch is incomplete.

Required correction: define one bounded skew policy and local monotonic ceremony
deadline across validators, guide confirmation, companion timers and recovery.
Retain strict creator-side expiry/replay checks. Do not simply accept arbitrary
future expiry values. Test both skew directions, expiry boundaries and replay.

### F3 — P1, source-confirmed: pause removes the active Apple-peer locator

`iOS/GetOverHere/Core/ApplePeerRoomTransport.swift:154`,
`Services/ChannelService.swift:95`, `Core/LocalControlPlane.swift:163`.
Connected listening pauses browsing, removes every endpoint and emits onLost.
The selected connector closes over `connect(roomID:)`, not a retained endpoint;
a later lane open calls an emptied dictionary. Rebuilding the route also loses
its Apple-peer membership. Browsing may restart as app state changes, but it does
not preserve the locator or guarantee rediscovery before recovery is exhausted.

Required correction: separate scan ownership from active-route ownership; retain
the enrolled/selected endpoint until route teardown, and resume browsing on real
path loss. Test an actual fresh lane open after pause and after replacement.

### F4 — P2, source-confirmed: expired stored hub identity has no renewal path

`Packages/LocalLinkSecurity/Sources/LocalLinkSecurity/LocalLinkIdentity.swift:22,103`;
Android `core/WiredCompanionTransport.kt:99`.
Swift returns the stored DER without a local validity check; creating a fresh
pairing reloads the same certificate. Android's existing alias has the same
eventual problem. The actual TLS suite correctly rejects an expired server cert;
the defect is recovery/provisioning, not acceptance of expired trust.

Required correction: explicit expired-identity status and deliberate renewal
followed by new two-way enrollment. Never silently rotate a confirmed DER pin.
Test renewal at both validity boundaries and preserve fail-closed Keychain errors.

### F5 — P1, source-confirmed: success precedes shared lane admission

Android `core/WiredCompanionTransport.kt:430` → `NearbySocketBridge.kt:104`.
The wire ACK is sent before `forwardConnected` reserves/promotes its shared-app
budget. Exhaustion then yields EOF after a success ACK instead of capacity.
The earlier forwarded admission/persistent semaphore is a different budget and
does not eliminate this failure. Test with the global bootstrap/lane budget full.
Required correction: acquire every necessary reservation and local resource
before ACK; send explicit capacity and release exactly once on every failure.

### F6 — P2, source-confirmed with narrower impact: silent nearby write timeout

Android `core/NearbySocketBridge.kt:283,289`; Swift counterpart:416.
The five-second deadline removes the group before the resulting exception reaches
the `connections.containsKey(id)` reporting guards. Native BLE/Aware paths can
therefore close without the intended error callback. Wired ingress also has an
outer rejection logger, so not every route is completely silent.

Corrections to supplied review: a group is one duplex lane, not all of a guest's
lanes. Normal direct LAN transports do not use this bridge. Writes are16KiB
chunks, not one60KiB operation. A bounded deadline itself is not inherently wrong;
silent failure and undocumented cross-platform policy are the confirmed gaps.
Required correction: report a typed timeout before teardown; define and test
reliable-lane deadlines separately from expiring audio, including asset resume.

### F7 — P1 recovery gap, but not mandatory reenrollment

iOS `Services/GatewaySessionCoordinator.swift:172,191` and
`Views/GatewaySetupView.swift:74`.
Automatic reconnect stops at five attempts without an explicit exhausted state.
An unchanged observed interface/address does not reset it. However, replugging
can be observed as interface disappearance/reappearance even with the same final
address; that does reset it. The companion's Connect button can explicitly retry
with its retained confirmed pins. Reenrollment is not always necessary.

Required correction: one explicit retry-exhausted state and a retry action for
both roles; reset its attempt budget on explicit retry or verified restoration.
Keep retained enrollment and local-guide listeners. Test outages longer than the
budget and restoration without a changed address, using a controllable clock.

### F8 — P1, source-confirmed: failed Android listener remains registered

Android `core/WiredCompanionTransport.kt:268,506,513`.
The accept-loop catch reports but does not retire the current server reference.
Recovery only re-listens when `server == null`. If the accept loop dies while the
same interface remains selected, the transport cannot autonomously re-listen.
Depending on socket state this can be a non-serviced backlog or refusal, not
necessarily immediate connection refused.
Required correction: identity/generation-guarded retirement and re-listen; inject
accept failure on the same interface and prove the replacement accepts bytes.

### F9 — P2 conditional, source-confirmed: alternate advertiser discarded

iOS `Core/ApplePeerRoomTransport.swift:90,105`.
With two endpoints reporting the same room, only one is selected. Removing it
clears the selection; an unchanged surviving record is not reinserted. The
specific example of an iPhone guide plus an iOS companion is outside the approved
mixed two-hub topology, but duplicate/stale/spoofed advertisements still exercise
the data structure. This is availability, not evidence of bypassing guide pins.
Required correction: retain candidates per room and select a surviving candidate
without trusting room-name/metadata alone; cover both removal orders and spoofed
guide identity. Combine with F3's route ownership work.

### F10 — P2, recovery UI divergence; native recovery is not dead

Android `service/GatewaySessionCoordinator.kt:233`, `ui/GatewayScreen.kt:110`,
`core/WiredCompanionTransport.kt:276,507`.
Production intentionally delegates to the native monitor, which does retry.
After its fifth failure the recovery task remains installed, while retry actions
can reset its budget. Thus the test-only coordinator loop is not itself a missing
production loop. The confirmed problem is absent native connecting/exhausted
state propagation: UI can expose Connect during an in-flight attempt; that call
throws and overwrites the useful error. A post-exhaustion explicit Connect can
work without reenrollment.
Required correction: one recovery owner with observable states and an idempotent
retry action; test the native-owned branch, not only fakes that turn it off.

## Additional security/resource findings

### F11 — P1: Android pre-authentication work lacks an absolute deadline

Android `core/WiredCompanionTransport.kt:386,390` uses `soTimeout=5000` around
TLS negotiation and `readFully`, but has no scheduled whole-operation deadline.
Likewise outgoing TLS and selector writes at365–375 lack a total operation bound.
Java's [SO_TIMEOUT contract](https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/net/Socket.html#setSoTimeout(int))
bounds individual blocking reads, not the entire handshake/header or writes.
Incremental traffic can retain scarce pending slots beyond the claimed five
seconds; a write stall is not bounded by that read timeout. This is a
source/contract-confirmed missing bound, not a demonstrated native TLS exploit.
An attacker must reach the selected wired listener; authentication bypass is not
required to occupy pre-authentication slots. There are eight such slots.

Required test before fixing: slow partial TLS/header traffic and a blocked GHL
write, proving slot/connection release under an absolute monotonic deadline and
that a legitimate paired client can proceed. The debug adapter already uses a
separate scheduled total deadline; do not confuse its coverage with the hub.

### F12 — P1: loopback socket leaks if the accepted reply write fails

Android `core/WiredCompanionTransport.kt:430–436` opens and registers `local`, then
writes the acceptance byte before entering its `try/finally` cleanup block. If
that write/flush throws, the outer finally closes the remote socket and releases
the semaphore but does not remove/close `local`. It remains retained in `sockets`
until whole-hub disconnect/stop. Repeated failed leaf acknowledgements can grow
retained sockets while the healthy control connection remains up.

This is source-confirmed exceptional control flow, not a physically executed
resource-exhaustion attack. Inject a failure at this exact write and assert local
socket, set entry and all leases are released while another listener survives.
Place ownership/cleanup around allocation itself; combine with F5, not a broad
transport refactor.

## Security properties inspected and evidence limits

- D1: Retain mutually pinned TLS1.3 and both scanned fingerprints. The executed
  LocalLinkSecurity suite passes valid bytes and rejects wrong server pin, wrong
  client pin, missing client identity and expired server identity. This does not
  test every trust callback/provider or certificate lifecycle.
- D2: Retain original-guide signing/admission authority. Inspected gateway paths
  forward fixed-lane bytes, validate descriptor room/guide/key binding, and do not
  create media credentials/signers on the companion. Inspected receiving paths
  verify a configured guide signature before opening encrypted frames. No new
  accept-all trust or arbitrary-destination proxy was found in those paths.
- D3: Keep debug control explicit, bounded and excluded from Release. Inspected
  Android handler authenticates HMAC before command execution, rejects replay,
  uses a loopback listener and an actual total request deadline. September11
  release/native evidence remains historical; it was not relabeled as a new run.
- R1: Open-room first contact is not verified human identity. Pin continuity is
  not a substitute for independent fingerprint verification. Shared short codes
  and changing a code do not imply PAKE security or member revocation. Those
  existing limits are not solved by the USB bridge.
- R2: This is a scoped code/security review, not a formal cryptographic audit,
  full dependency penetration test or proof that no other defect exists. No ASan,
  TSan, physical radio, locked-phone or long-duration stress result is claimed.

Dependency advisory check: the resolved swift-crypto4.5.2 is newer than the fixed
versions for the published [RSA double-free advisory, fixed4.5.1](https://github.com/apple/swift-crypto/security/advisories/GHSA-8q93-f6xh-4f6f)
and [X-Wing length advisory, fixed4.3.1](https://github.com/apple/swift-crypto/security/advisories/GHSA-9m44-rr2w-ppp7).
The checked [swift-certificates advisory page](https://github.com/apple/swift-certificates/security/advisories)
lists no published advisories. JmDNS's public advisory page did not provide a
complete substantive result in this retrieval; no clean dependency bill is
claimed. No dependency was upgraded during review.

## Executed evidence

Run `bash scripts/review/gateway/run.sh`. The isolated Swift review package and
Gradle init-script source injection call the real core/capture code without
changing normal app source sets. Exit0 means the desired regression checks pass;
nonzero requires inspecting actual test failures versus environment/build errors.
No mock encoder result is presented as native microphone/audio quality.

September15 run `/tmp/GetOverHereSecurityReview.RpOF5q`:

| Check | Observed result |
|---|---|
| Swift skew regression |1 selected,1 failed: `.expired`|
| Android review regressions |3 selected,3 failed: skew and both encoder replacement assertions|
| Normal Android app suite, no review injection |198 tests/37 suites passed; Gradle exit0|
| LocalLinkSecurity actual TLS |4 test definitions/8 cases passed; exit0|

The Kotlin core task was UP-TO-DATE in the normal rerun, not newly re-executed.
Logs are retained as text under `benchmarks/2026-09-15-security-review/`.
No commit/push, production fix, phone access or radio change occurred.

## Ordered work possible before devices return

- A1: Fix F1 with bounded failure/stall recovery, live counters and signed-output
  regression; keep existing no-churn startup cases.
- A2: Fix F2 and F4 together as explicit enrollment/identity lifecycle policy,
  with mirrored skew/expiry/replay/renewal tests. No silent pin rotation.
- A3: Fix F3/F9 using active-route ownership plus multi-candidate discovery; prove
  fresh control/asset/admission lane opens after browsing pauses.
- A4: Fix F5/F11/F12 with atomic reservation, absolute pre-auth deadlines and
  exception-safe resource ownership. Add saturation/slow-reader/ACK-failure tests.
- A5: Fix F6/F7/F8/F10 with one observable recovery owner, explicit exhausted and
  retry states, per-lane timeout reporting, and same-address restoration tests.
- A6: Rerun both app suites, protocol parity, real Mac/Android-emulator TLS, setup
  UI, debug/release exclusion and fault-driven software endurance; freeze builds.
- A7: When devices return, run FieldAcceptance A13–A20 once against that candidate.
  Hardware findings may still require code changes; no honest review can promise
  that one physical round will uncover nothing further.
