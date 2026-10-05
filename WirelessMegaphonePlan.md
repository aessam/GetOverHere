# Wireless megaphone + PDF plan (October 4, 2026)

Goal (Sept 21 direction, issue #5): one guide speaks and turns PDF pages; iPhone and
Android guests hear and follow, with no Internet and no shared router.
Branch `fix/deep-dive-2026-09-02`, HEAD `7391db7`. Keep one cross-platform app.

## Starting evidence

| Fact | Source |
|---|---|
| iPhone12mini↔Pixel11Pro over Bluetooth, no AP, normal UI: PASS in both guide roles | `ExperimentLog.md:1507-1521` |
| One Android-guide rerun stalled at "Waiting for Audio"; Android logged repeated Opus encoder recreation; undiagnosed | same |
| Bluetooth payload rate per guest: iPhone guide 0.53 Mbps, Android guide 0.25 Mbps; RTT p50 30–60 ms | `benchmarks/2026-09-10/README.md` |
| Asset lane is request-driven 60 KiB chunks; no route-aware pacing found in production code (grep, Oct 4). 524,288 B/s was only the benchmark load | `CLAUDE.md`, benchmark README |
| Android encoder retirement is already bounded (`MAXIMUM_ENCODER_REPLACEMENTS`) and logs a reason string; the bound came from F1 (Sept 15) | `UDPAudioPlane.kt:203-216` |
| Android has `strictAwareOnly`; there is no Bluetooth-only policy; no equivalent found on iOS (grep, Oct 4) | `ChannelService.kt:136-143,607,1222` |
| Slides are image assets (`TourAssetKind.slide`) with current-slide-first scheduling; no PDF code exists | `AssetPayloads.swift:57`, `TourContentStore.swift:54` |
| FND-2: playback clock baseline only moves down; modeled silence after 76.7 min at +100 ppm (ppm not measured) | `RealtimeAudioBuffer.swift:169`, `.kt:151` |
| FND-1 encoder-recovery fix committed locally, not pushed | `5c13e79` |

## Decisions needed before Phase 4

- **DSCN-1 PDF wire format.** Recommended: **render pages to images on the guide and send them as
  existing slides**. That needs no wire change, no new asset kind and no Swift/Kotlin parity work.
  It reuses current-slide-first scheduling, and the guide's page number maps to the slide index.
  The cost is fixed resolution, so no vector zoom. The alternative sends the whole PDF as a new
  asset kind: a 5 MB file at 0.25 Mbps takes about 160 s per guest before page 1 shows, and it
  needs a cross-platform wire change.
- **DSCN-2 Hotspot fallback.** A phone hotspot with no Internet puts everyone on one LAN, so the
  existing LAN path works with no code. Decide whether that counts as allowed under "no shared
  router". It is a field fallback only, never a silent automatic route.
- **DSCN-3 Push.** Local commits `5c13e79` and `7391db7` are not pushed. Push only when you say so.

## Phase 0: Housekeeping (about 30 min, no devices)

1. Replace the top of `NextSession.md` with a pointer to this plan, plus the Sept 22 review and
   the Sept 23 FND-1 fix.
2. `scripts/verify_tour_session.sh` step 9: make the simulator destination overridable
   (`GOH_IOS_DESTINATION`) and add a preflight that fails clearly if it is missing, instead of
   xcodebuild exit 70.
3. Record DSCN-1/2 in `ADR.md` once you decide them.
4. Gate: run `scripts/verify_tour_session.sh` in full at HEAD and record counts in
   `ExperimentLog.md`. This is the baseline for every later phase.

## Phase 1: Make the Android-guide encoder recreation visible: DONE, no code needed

Checked Oct 4. The Sept 10 stall predates the F1 repair (Sept 15) and the FND-1 fix (Sept 23).
- Recreation is capped at 3 per codec per tour (`UDPAudioPlane.kt:105,203-216`). Exhaustion raises
  `AudioSessionEvent.Failed`, a visible guide error (`:500-502`), and has a test (`RealtimeCaptureInboxTest.kt:120-131`).
- Count and last reason (`"no output for 2 seconds"` or the exception class) already reach debug status as
  `audioCapture.encoderResetCount` / `lastEncoderResetReason` (`GatewayDebugControl.kt:306`).
- Guests keep playing across a replacement (`5c13e79`).
Phase 5 reads these fields during the Android-guide repeats.

## Phase 2: Explicit Bluetooth-only route policy (issue #1 software slice): DONE `46f6932`, ADR-074

Without it, a physical "Bluetooth pass" can quietly be a LAN or Aware pass.

1. Android: replace `strictAwareOnly: Boolean` with `RoutePolicy { AUTOMATIC, AWARE_ONLY,
   BLUETOOTH_ONLY }` in `ChannelService`. Keep the existing switch behavior mapped to `AWARE_ONLY`.
   Apply the policy at the two existing gates (`:607` LAN host suppression, `:1222` route check).
2. iOS: add the same enum to the guest join path in `ChannelService.swift`, with the same rejection
   semantics. Debug/test builds only; no product UI unless you ask.
3. Tests, both platforms:
   - `BLUETOOTH_ONLY` + LAN-advertised room: no LAN connect attempted, and an explicit error if Bluetooth is unavailable.
   - Reconnect after drop under `BLUETOOTH_ONLY` stays on Bluetooth.
   - Route provenance reported in status equals `BLUETOOTH`.
   - Mutation: delete one policy check in a scratch copy and confirm a test fails on the assertion, not on compilation (`scripts/verify_audio_recovery_mutation.sh` pattern).
4. Exit: both suites green, and the mutation is killed.

## Phase 3: Long-tour audio correctness: FND-2 and FND-10 DONE `652bcaf` (ADR-073); FND-8 DEFERRED

1. **FND-2** in both cores in one patch. Re-anchor the clock-offset baseline: track a windowed
   minimum (for example, the last 10 s) instead of the minimum over the whole tour, so slow drift in either
   direction is followed. Add Swift and Kotlin tests that replay the `repro/jitter-drift` model at
   ±100 ppm over 4 simulated hours with zero expired frames, plus a step-change test. Run
   `scripts/verify_tour_session.sh` (exact-bytes parity is unaffected, but the gate is mandatory).
2. **FND-10** iOS guest playback backlog: cap scheduled-but-unplayed buffers in
   `AudioEngine.swift:136` (drop oldest above about 200 ms) so a main-thread stall cannot add
   permanent latency. Unit-test the scheduler with a fake player node.
3. **FND-8 deferred (Oct 4):** a deeper capture buffer only bursts delayed audio to guests, whose
   jitter buffer holds 13 frames (260 ms). The fix needs capture timestamps taken in the tap and
   submission off the main actor. PDF rendering stays off the main actor so it cannot cause these stalls.
   FND-10's renderer flush is unit-tested but needs a device run to confirm.
   Original item: **FND-8** iOS guide capture: move the capture consumer off the main actor (`@concurrent`) and
   raise the buffer above 1. Test: a 300 ms main-actor block loses no captured buffers.
4. Exit: core parity gate green; iOS and Android suites green.

## Phase 4: PDF as page images (assumes DSCN-1 = page images)

1. Import:
   - iOS: add `.pdf` to a guide `fileImporter`; render with PDFKit `PDFPage.thumbnail(of:for:)`.
   - Android: `ACTION_OPEN_DOCUMENT` with `application/pdf`; render with `PdfRenderer`.
   - Clear errors for encrypted, corrupt or zero-page files. Never import partially.
2. Render budget, sized for Bluetooth: long edge 1600 px JPEG at quality 0.75, target ≤250 KB per
   page. At 0.25 Mbps, a 250 KB page takes about 8 s and the current page goes first.
   - Hard caps: 60 pages and 15 MB total per tour; reject above the cap with a message that gives the numbers.
3. Each page goes through the existing `importSlide`/`importSlides` pipeline, so the guide's slide
   index is the page number. Late join and reconnect already restore the current slide.
4. **Audio priority on Bluetooth (RSK-3, open question):**
   - Assets and audio use separate lanes, but on Bluetooth they share one 0.25–0.53 Mbps radio link.
   - Test: run the real lane writers over a throttled loopback at 0.25 Mbps and assert an audio-frame latency bound while a 250 KB page streams.
   - If it fails, add asset pacing that follows the route.
5. **Guest cache bound (FND-13):** the guide-side cap does not bound the guest. Add a guest
   per-tour byte cap, prune past-tour cache, and set `isExcludedFromBackup` on the iOS cache.
6. Tests: a deterministic 3-page fixture PDF is checked in; page count, render size and hash are
   stable across runs; the corrupt and encrypted fixtures are rejected; a UI test imports the PDF
   and advances pages on simulator and emulator.
7. Exit: both suites green; the fixture PDF reaches the guest as slides in the existing
   emulator↔simulator LAN integration path.

## Phase 5: Physical acceptance (issue #4); needs your phones

Do not probe devices until you say they are available. Use `scripts/verify_mixed_normal_ui.py`.

1. Rebuild both apps at the final HEAD and record hashes.
2. Pair iPhone13Pro + Pixel11Pro, both with Wi-Fi forgotten and `BLUETOOTH_ONLY`. The Sept 10 pass
   used an iPhone12mini, so the iPhone13Pro over Bluetooth is unproven (RSK-2).
3. Test both guide directions:
   - Create/join, then lock code on/off.
   - Live speech: check the renderer byte counters and listen.
   - PDF import and page turns, with late join mid-deck.
4. Android-guide repeat ×5 to reproduce or clear the "Waiting for Audio" stall, using the
   Phase 1 counters.
5. Locked guest screen, 10 min. CoreBluetooth background behavior is unproven (RSK-4).
6. 30 min endurance with speech + page turns. Run 90 min only after 30 min passes (FND-2 check).
7. Add Pixel7 as a second guest only after the pair passes. Publish only the measured cap.
8. If DSCN-2 = yes: one hotspot run on the plain LAN path as the documented fallback.
9. Record PASS/FAIL/NOT RUN per step in `ExperimentLog.md`; open an issue for each failure.

## Risks

- **RSK-1** Group capacity on Bluetooth is unmeasured. One iPhone with two Androids measured 0.22–0.47 Mbps
  each, not synchronized. Voice is about 32 kbps, so audio likely fits; PDF fan-out to many guests is slow.
- **RSK-2** iPhone13Pro has never run the Bluetooth path.
- **RSK-3** Asset traffic may starve audio on the shared Bluetooth link; untested (Phase 4.4).
- **RSK-4** Locked iPhone guests over CoreBluetooth L2CAP are unproven.
- **RSK-5** The stall root cause may be outside the encoder (Phase 1 only makes it diagnosable).

## Order and gating

Phase 0 → 1 → 2 → 3 → 4 can all run now without devices. Commit after each phase, once its exit gate passes.
Phase 5 waits for you. No product-completion claim before Phase 5 passes.
