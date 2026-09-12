# GetOverHere — consolidated field acceptance

## September 11 two-hub acceptance

The current approved mode is specified in `GatewayImplementationPlan.md` (ADR-069).
Two hubs only, either guide orientation, original guide authority, USB between
hubs, Apple peer-to-peer iOS listeners and Aware Android listeners. Companion
keep-awake is permitted; audience keep-awake cannot pass the lock gate. A qualified
cap below30 is acceptable. No listener relays or invisible LAN/Bluetooth fallback.

Physical gateway status: **NOT RUN**. Initial implementation preflight found both
Pixels unreachable through their saved wireless ADB endpoints. The historical
September10 Bluetooth/Aware measurements and September11 USB ping do not qualify
the combined gateway. Do not erase them or relabel them as these test results.

Use `scripts/verify_gateway_system.py` and its pinned manifest/evidence contract
with the final coordinated builds. See `scripts/gateway_tools.md` for device
preflight, authenticated app control, local recording and later evidence export.
First chain: iPhone guide → USB → Android
companion → Aware Android listener. Then add an iOS peer listener and reverse
guide/companion roles. Required full-system minimum is two iPhones and two Androids.
Retain hardware provenance, certificate rejection, per-leaf identity/readiness,
exact asset resume and real microphone/acoustic evidence. Progress10min smoke →
30min stress →90min walking, with the numerical targets from the approved plan.
Exercise several minutes of silence/pause while listeners stay locked, then
resume speech. Record both USB power directions. A controller-free test must not
depend on debug keep-awake or silently route through the management network.

### Current two-hub run, in one device session

| ID | Exercise | Pass evidence |
|---|---|---|
| A13 | Record all four devices/build hashes; confirm actual USB data/power roles and wired addresses. Leave Wi-Fi/Bluetooth enabled, with no AP association during strict branch checks. | Correct artifacts, idle apps, physical route evidence; no management-network fallback. |
| A14 | Create the room on the guide. Open Gateway setup, select the observed wired interface and show the public pairing QR. Companion scans it; guide scans the response and confirms; companion connects. | One original room/guide key, mutually authenticated wired connection. The two QR steps enroll hubs; they are not a mandatory guest room code. |
| A15 | Join one Android over Aware and one iPhone over Apple peer-to-peer. Exercise open/locked/wrong-code/correct-code and edit/unlock. Speak, change slide/target, and add an uncached asset. | Both actual listeners receive authoritative state and speech. Connected, audio-ready and audible are recorded separately; all asset hashes match. |
| A16 | Unplug/replug the hub cable during speech and an asset transfer; repeat with a changed wired address. Move a listener out of range/back and end a tour during recovery. | The guide-local branch stays up; companion withdraws on loss; no stale speech/key substitution; state and exact remaining asset bytes recover. Report native link restoration separately from playback recovery. |
| A17 | Reverse guide/companion roles and repeat A14–A16. | Same application checks and route evidence in the other orientation, not an assumed symmetric result. |
| A18 | Lock guide/listeners with real speech, several minutes of silence/pause, resumed speech, app switching and supported interruptions. Leave only the companion's explicit production keep-awake enabled. | Continuous actual listening/capture where required, genuine lock/lifecycle evidence, no debugger keep-awake substituted for a locked pass. |
| A19 | Run10min smoke,30min stress, then90min walking with assets and weak-edge listeners. Increase audience only while measured gates pass; test cap−1/cap/cap+1. | Acoustic reference recording, per-listener loss/readiness, recovery, battery/thermal and bounded resources. Four phones do not establish thirty-listener capacity. |
| A20 | End only the owned test tours/recorders/debug endpoints; export one evidence bundle with failures and reruns. | Cleanup verified; source/build/device manifest and PASS/FAIL/NOT RUN matrix retained. No secrets or unrequested radio restoration. |

The user confirmed on September11 that physical devices will be available again
after returning to the workstation. Do not request intermediate field runs or
attempt phone installs while that restriction remains in effect.

The older checklist below remains historical broader-route qualification. Its
relay/mandatory30 target does not expand this approved two-hub scope.

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
Row A13–A20 (current two-hub run), or A1–A12 (historical route checklist):
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
