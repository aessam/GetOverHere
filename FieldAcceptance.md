# GetOverHere — consolidated field acceptance

Status: **not executed**. September 8 coding uses host tests, iOS Simulator and Android emulator only; the user is away from physical devices. This checklist is for one later integrated candidate, not a request to test intermediate builds.

The target is one guide plus 30 mixed listeners, outdoors, no router or Internet dependency. Both radios may remain enabled. System pairing is allowed; the optional editable **Lock Room with Code** remains separate. LAN is the preserved fallback, not a replacement requirement.

## Candidate and evidence

Before installation, record the exact commit, dirty/clean state, iOS build, Android APK SHA-256, device model, full OS version, role and route. Install the same coordinated admission-v2 generation on both platforms. Keep `stable-local-network` unchanged; that older tagged app pair uses the older protocol.

Software results and open implementation work live in [NextSession.md](NextSession.md) and [ExperimentLog.md](ExperimentLog.md). The two archived research reports are [RES-C](Research-Claude-2026-09-08.md) and [RES-G](Research-ChatGPT-2026-09-08.md); their proposed thresholds and platform claims are not passed acceptance tests.

Never mark an unsupported/unavailable route as passed by observing a LAN fallback. Record actual Bluetooth/Wi-Fi Aware/local-network provenance. A socket welcome, renderer-ready report, native codec fixture and audible microphone-to-speaker output are different evidence.

## Ordered run

| ID | Exercise | Required observation |
| --- | --- | --- |
| A1 | Cold launch, Find Nearby, Create, grant/deny permissions and retry | No launch radio prompts; requests follow user intent. Denial and missing hardware give an actionable error. Failed microphone startup leaves no misleading LIVE room. |
| A2 | Open room; lock; wrong code; correct code; edit code; unlock | No app code required for an open room. Wrong code fails without downgrade. New joins use the current policy; existing admitted listeners stay connected. Editing a code does not claim member revocation. |
| A3 | Join/cancel/retry with an Android guide, then an iPhone guide | Join progresses through route/admission/audio. Cancellation cannot later join a stale room. Guide connected count and audio-ready count remain distinct; listen to actual speech. |
| A4 | Compare optional guide fingerprints; rejoin and change route | Same-session guide key remains pinned. A substituted key is terminal, not silently accepted. First contact is unverified unless the fingerprint is independently compared. |
| A5 | Shared LAN with Internet disconnected | Megaphone, slides, pointer and map target work in both guide directions. Guest location/heading stays local. This establishes only the LAN row. |
| A6 | No AP association, radios enabled | Verify native route before sending. Exercise Android compatibility Aware and eligible public system pairing separately. A first-time OS PIN is not the room code. Unsupported publisher/profile is an explicit blocked row, not a successful mixed-Aware test. |
| A7 | Wi-Fi radio disabled, Bluetooth enabled | Repeat admission, speech, current slide and target over actual BLE, in both guide directions. Record the largest passing group separately; restore and verify original radio settings. Never call this Wi-Fi Aware. |
| A8 | Add an uncached late listener during speech; jump to another slide while bulk assets transfer | Current state arrives first, current/next content is prioritized, hashes match and partial content resumes. Missing content is visible as transferring/failed; audio does not silently accumulate stale frames. |
| A9 | Lock active guide/listeners; app switch; call/alarm; headphones unplug; mic/playback retry | Genuine active audio continues where supported. Interruption status is accurate; explicit retry recovers without replacing the room/key or discarding unrelated control/assets. Lock is not equivalent to app suspension. |
| A10 | Move a listener out of range and back; change radios/route; end the tour during reconnection | Pin/session retained; old callbacks cannot revive the ended room or close replacement links. Audio/state is not played twice. Record outage/recovery duration and actual route. |
| A11 | Capacity minus one, capacity, plus one; then grow toward 30 listeners | No healthy guest evicted for overflow. Capacity errors name the exhausted resource. Every claimed listener hears speech and receives state; software socket limits are not NDP or airtime capacity. Do not attempt relay acceptance until native relay authorization/forwarding is implemented. |
| A12 | 60–90 minute outdoor walk with mixed phones, randomized locks, edge-of-range listeners and paced assets | Record per-device disconnects, audible loss, latency/skew, battery and thermal observations. Two-phone bulk throughput cannot pass this row. |

Acoustic latency and speaker-to-speaker skew require a shared external recording/reference, not subtraction of unsynchronized phone clocks or RTT/2. Agree the numerical listening thresholds before a measured run; retain raw observations even on failure. A simulator cannot substitute for A6/A7/A9/A11/A12.

## Existing diagnostic harnesses

Run only after the specific devices and radio changes are available and authorized. Physical fixture passes do not replace the actual-app/acoustic checks above.

- `scripts/verify_virtual_devices.sh`: integrated software gate; explicitly accepts emulator serials only.
- `scripts/verify_nearby_physical_android.sh`: two Android native transport fixtures; use explicit guide/guest serials and selected transport, then reverse roles.
- `scripts/verify_nearby_cross_platform.sh`: iPhone/Android direct BLE fixtures, both guide orientations.
- `scripts/benchmark_android_aware.sh`: default synthetic bulk benchmark; `--profile tiny` adds50pps signed/encrypted synthetic codec-sized probes, idle and paced-asset phases, raw RTT/send-lag and offered/drop accounting. This uses Aware TCP with the guide-side asset adapter, not direct UDP or the production realtime ACK lane, and is not a speech/30-person gate. Missing echoes fail the run. `--smoke-only` uses only the explicit emulator.
- `scripts/capture_physical_test.sh`: scoped logs for an explicitly selected physical run.

Do not start an automatic retry loop on pairing failures. Capture profile eligibility, failing operation and the original error. `NWError.wifiAware(-11992)` has no verified meaning in this project.

## One feedback bundle

```text
Candidate commit/builds:
Device model + full OS + guide/listener role:
Row A1–A12:
Expected / observed:
Actual route (including any fallback):
AP association / Wi-Fi radio / Bluetooth state:
Room lock state (do not include the code):
Connected / audio-ready / actually audible listeners:
Screen locked / foreground / interrupted:
First failure timestamp and recovery duration:
Scoped logs / screenshot / acoustic recording:
PASS / FAIL / NOT RUN / BLOCKED (reason):
```

Never include room secrets, pairing PINs, application keys or unrelated device logs in the bundle. Keep failed attempts alongside passing reruns. The supported group size is the largest qualified group on the tested fleet, not the number of sockets accepted by a simulator.
