# Gateway verification tools

These tools separate software checks, physical measurements, and missing evidence.
They do not manufacture native scenario results. `tests/fake_gateway_driver.py`
is a unit-test dependency only and must never appear in a physical run manifest.

## Host gates

```sh
python3 -m unittest discover -s scripts -p 'test_gateway_tools.py' -v
python3 scripts/verify_gateway_protocol.py /path/to/tour-session-swift /path/to/tour-session-cli --output /tmp/gateway-protocol.json
```

The first command includes a real loopback TCP roundtrip and needs local socket
permission. The second uses already-built Swift/Kotlin core CLIs; it verifies
ten identical fixture lines, both decoder directions, malformed/truncated binary
records, and canonical/invalid QR strings. Neither is physical radio evidence.
The core-parity and main tour-session gates now include gateway protocol parity.

## Read-only phone inventory

```sh
python3 scripts/probe_gateway_android.py SERIAL_OR_WIRELESS_ADB_ENDPOINT
python3 scripts/probe_gateway_android.py SERIAL --artifact Android/app/build/outputs/apk/debug/app-debug.apk
```

The optional artifact is checked against `pm path` plus the installed APK's actual
`sha256sum`. Split APK installs fail explicitly. Inventory does not install, stop,
unlock, or change radios. It is not a completed preflight without an authenticated
application status observation. `--status-command` accepts a JSON object with
`argv` and `timeout_s` invoking `gateway_android_control.py DEVICE status`.
The private credential read and ADB tunnel bind that result to the selected device,
not a guessed hardware ID inside the app.

### Android live control and local recording

Open the debug-only consent activity with authorized ADB, then press **Enable debug
control for 10 minutes** visibly. Opening the activity does not activate it:

```sh
adb -s DEVICE shell am start -n com.aessam.comeoverhere/.debug.GatewayDebugActivity
python3 scripts/gateway_android_control.py DEVICE status
python3 scripts/gateway_android_control.py DEVICE create --arg name=GatewayTest
python3 scripts/gateway_android_control.py DEVICE scenario-start --arg seconds=120 --arg runID=UUID
python3 scripts/gateway_android_control.py DEVICE scenario-status
python3 scripts/gateway_android_control.py DEVICE export-scenario --scenario-id RECORDING_UUID --output /tmp/android-recording
```

The localhost-only server uses TLS 1.3 and the same payload/MAC framing as iOS.
The client reads the ephemeral key and certificate pin via scoped `adb run-as`,
verifies the server pin before sending a request, and removes its own temporary
ADB forwarding rule afterward. No credential is printed. Room codes use an
owner-controlled `--arguments-file` JSON, not process-list-visible command arguments.
Endpoint lifetime is ten minutes, with at most four clients, ten-second requests,
32 KiB frames, and 2048 non-replayed request IDs. There is no remote shell/proxy.
Release does not contain this activity, server, recorder, or identity alias.

Fixed commands are `status`, `gateway-status`, `gateway-begin`, `gateway-pair`,
`gateway-confirm`, `gateway-connect`, `gateway-stop`, `strict-aware`, `discover`,
`create`, `join`, `leave`, `room-lock`, `next-slide`, `previous-slide`, `retry-audio`,
`restart-microphone`, `output`, `scenario-start`, `scenario-status`, and
`scenario-cancel`. They operate the application-owned services, not a second test
coordinator. Mutations require foreground and existing OS permissions. Ambiguous
wired interfaces require an explicit `interface` argument matching status output.

The local recorder requires an active tour/connected companion, accepts 10..7200
seconds, records actual state at one-second intervals, and continues independently
of the Mac and debug endpoint expiry. It never keeps the screen/process awake.
It saves session identity, requested-run nonce, monotonic times, role/generation,
real renderer/capture counters, same-room/active checks, lock, battery and thermal
observations. It records no microphone content or room code. Export remains possible
through ADB after the endpoint expires. The consent screen also has local Start and
Cancel controls. At most twenty recordings are retained; it refuses more instead of
deleting earlier evidence.

```sh
python3 scripts/verify_gateway_android_debug.py --output /tmp/debug-adapter-run
python3 scripts/verify_gateway_android_control_ui.py --grant-microphone --output /tmp/debug-ui-run
python3 scripts/verify_debug_control_release.py Android/app/build/outputs/apk/release/app-release-unsigned.apk
```

The component runner rejects physical devices, checks installed APK hashes, and
requires exactly five passing real emulator TLS/HMAC tests, including explicit
listener-close fault cleanup and a latched stop-during-startup race. `--install` explicitly
installs selected built test APKs. It does not qualify a radio/audio path.
The UI runner also rejects physical devices. It taps the visible consent button,
uses the real pinned Python client, starts guide capture, and exports ten seconds
of native continuity observations. It then leaves its room, disables its endpoint,
and restores any microphone permission it explicitly granted. Existing active
debug sessions are refused. Emulator capture is not acoustic qualification.

### iOS controlled receipt and read-only probe

`probe_gateway_ios.py` uses public `devicectl` commands. Select the exact UDID and
set `DEVELOPER_DIR` to the intended Xcode. `--status-command` is a JSON argv command
calling the existing pinned `goh-control ... status` CLI. A private endpoint file
copied through the selected device's app container ties that network status to the
correct app instance.

```sh
python3 scripts/probe_gateway_ios.py UDID --app /path/GetOverHere.app --status-command /path/ios-status-command.json --install-and-record /tmp/ios-install-receipt
python3 scripts/probe_gateway_ios.py UDID --app /path/GetOverHere.app --status-command /path/ios-status-command.json --receipt /tmp/ios-install-receipt/receipt.json --radio-observation /path/ios-radio-observation.json
```

The first command is explicitly mutating: it refuses an active tour, installs the
selected bundle, and retains successful install plus external bundle/build evidence.
It does not relaunch/activate debugging; use the existing authorized debug activation
workflow after installation. The second is read-only. An initial app/debug bootstrap
is a separate existing deployment step; there is no "assume idle" bypass.

The .app digest includes all files, including debug dylibs/resources, not merely the
launcher executable. iOS cannot generally read back the installed signed bundle:
this evidence is labeled controlled installation plus external metadata, weaker
than Android's installed-file hash. Unknown `devicectl` schema fails explicitly.

Wi-Fi enabled must not be guessed from peer-to-peer opt-in. A radio observation is
an explicit JSON `{device_id, wifi_enabled: true, source, observed_at}` made from
Settings/operator observation within ten minutes. `source` is
`operator_settings_observation` or `device_settings_capture`; `observed_at` is an
ISO-8601 timestamp with timezone. Keep corresponding field notes/screen capture.

### Native recording export and result adapter

iOS uses existing `gateway-record seconds=N runID=UUID`, `gateway-record-cancel`,
and its in-app record/share controls. Export the explicitly selected recording:

```sh
python3 scripts/export_gateway_ios_recording.py UDID RUN_UUID --output /tmp/ios-recording
python3 scripts/gateway_recorder_result.py --platform ios --trace /tmp/ios-recording/observations.jsonl --verified-probe /path/ios-probe.json --minimum-seconds 120 --expected-run-id RUN_UUID --scenario-id continuity --output /tmp/continuity/result.json
```

Android supplies both `--trace observations.jsonl` and `--summary summary.json`.
Inside the runner, run/scenario IDs, result path and verified probe location come
from its environment. Request the native recorder with the runner's exact nonce.
The adapter requires positive actual native counts and computes four checks:
complete recording, same-room/active continuity, sampling duration/cadence, and
verified build/app identity. Configure `expected_tests: 4`; `--locked` adds a fifth
check. Assertions are prefixed with the manifest device ID. It rejects stale nonces,
wrong apps, zero/mismatched counts and sampling gaps greater than 1.5 seconds. Raw
native/probe files are copied into the result evidence, never replaced by summaries.

An iOS room's `locked` field is not screen-lock evidence. A locked gate needs explicit
`screenLocked` observations, otherwise it fails. Missing mapped native route peers
remain missing routes; the result cannot pass a strict physical route requirement.
Passing these four/five checks establishes sampled application continuity only,
not acoustic quality, physical capacity or the full tour product.

## Scenario runner

```sh
python3 scripts/verify_gateway_system.py /path/to/manifest.json --mode dry-run
python3 scripts/verify_gateway_system.py /path/to/manifest.json --mode preflight --output /tmp/gateway-run
python3 scripts/verify_gateway_system.py /path/to/manifest.json --mode run --output /tmp/gateway-run --resume
python3 scripts/verify_gateway_system.py --mode collect --output /tmp/gateway-run
python3 scripts/verify_gateway_system.py --mode report --output /tmp/gateway-run
```

The manifest is a trusted executable test configuration, not untrusted downloaded
data. Commands are argv arrays, never shell text. Output must be outside the source
tree; do not put credentials in command arguments or logs. Dry-run hashes artifacts
and validates configuration without contacting phones. Preflight checks all devices
before starting any task. Tasks in one scenario run concurrently; scenarios run
sequentially and stop on failure. Device locks protect against other runs of this
runner; they cannot detect unrelated external experiments, which the operator must
stop before use. Existing active tours are rejected rather than overwritten.

Required manifest fields:

- `schema: 1`, `name`, explicit uint32 `seed`, exact 40-character `revision`.
- `devices`: at least guide, companion, listener. Each has `id`, `platform` (`ios`
  or `android`), `role`, expected `model`, expected `os`, `artifact: {path, sha256}`,
  and `probe: {argv, timeout_s}`. Exactly one guide and one companion, on different
  platforms. Artifact paths resolve relative to the manifest.
- `scenarios`: unique `id`, boolean `required`, `classification` (`software` or
  `physical`), boolean `requires_locked_listeners`, nonempty `required_assertions`,
  and `tasks`. Each task has unique `id`, `device_id`, `argv`, `timeout_s`, positive
  `expected_tests`, and a distinct relative `result` path.
- Physical scenarios require `required_routes: [{from, to, transport}]` and scoped
  `cleanup: [{argv, timeout_s}]`. Transport is `usb`, `android_aware`, or
  `apple_peer_to_peer`. Cleanup must stop only work this run started.

Commands have 1..10800-second deadlines and 32 MiB log bounds. Subprocess groups
are terminated on timeout/cancellation. Cleanup runs after scenarios, including
failed ones, and cleanup failure fails the attempt. Use `--scenario ID` to select
one or more scenarios; unselected scenarios remain NOT RUN.

### Probe result contract

Probe stdout must contain exactly one JSON object with:

`id`, `platform`, `model`, `os`, `installed_sha256`, `physical: true`,
`session_state: "idle"`, `wifi_enabled: true`, `debugger_attached: false`, and
`artifact_verification: {method, verified: true}`.

Android's method is `adb_sha256`. iOS uses
`controlled_install_and_external_metadata`: the adapter must retain a successful
controlled `devicectl` install receipt for the exact artifact and device, then
query the installed bundle identifier/build externally. This is weaker than hashing
the installed iOS bundle, and is labeled as such. Native app self-reported archive
hashes are not accepted. The adapter is implemented above; physical execution and
current device/radio evidence are still required, never substituted with fixtures.

### Native task result contract

Each command receives `GOH_RUN_ID`, `GOH_SCENARIO_ID`, `GOH_SCENARIO_SEED`,
`GOH_RESULT_PATH`, and `GOH_ATTEMPT_DIR`. It must write actual observations, not
expected values, to `GOH_RESULT_PATH`:

```json
{
  "schema": 1,
  "run_id": "the supplied GOH_RUN_ID",
  "scenario_id": "the supplied GOH_SCENARIO_ID",
  "device_id": "the assigned manifest device",
  "classification": "physical",
  "installed_sha256": "the artifact verified by the host adapter",
  "tests": {"executed": 1, "passed": 1, "failed": 0, "skipped": 0},
  "assertions": {"descriptive_observable_assertion_id": true},
  "evidence": [{"path": "native-observations.json", "sha256": "actual file digest"}],
  "routes": [],
  "lifecycle": []
}
```

This illustrates the contract, not a runnable result fixture. Positive test counts
must match the exact expected count. Every required assertion must be observed;
an absent result, skipped test, stale run ID or wrong artifact fails. Raw evidence
must exist, be nonempty, remain under the attempt directory and match its digest.

Each required route must have matching `from`, `to`, `transport`, `connected: true`,
a nonempty `interface`, and `fallback_used: false`. Android Aware also requires
`network_id`. Apple peer-to-peer requires `infrastructure_associated: false`.
Unknown transport identity does not pass. Locked-listener evidence requires one
or more `lifecycle` observations per listener containing `device_id`, `locked: true`,
`debugger_attached: false`, and `debug_keep_awake: false`. These are samples; scenario
assertions and raw lifecycle traces must establish the full specified interval.

### Evidence and resume

`state.json` preserves every failed and successful attempt; `report.json` displays
PASS/FAIL/NOT RUN and earlier failures. A failed attempt is never overwritten.
`bundle.json` inventories all evidence files with SHA-256. Collect/report recheck
the inventory, probe outputs, and successful task results without contacting phones.
This detects accidental changes; it is not a cryptographic signature proving who
produced the evidence. Copy the entire directory for offline collection.

Resume requires the same manifest, artifact hashes, git revision and working-tree
digest, plus intact earlier evidence. It repeats preflight, skips only latest PASS
scenarios, and appends a new attempt for failures. A source/configuration change
requires a new output directory. No physical result currently exists merely because
the runner's own software fixtures pass.

## Acoustic analysis

Use one externally recorded, simultaneous multichannel PCM WAV: a reference at the
guide input and separate listener output channels. Isolate direct acoustic leakage;
document microphone geometry, output route and propagation distance. Pure/repeated
tones are unsuitable for unambiguous matching. No tool starts microphone recording.

```sh
python3 scripts/analyze_gateway_acoustics.py /path/to/capture.wav --reference-channel 0 --listener-channel 1 --listener-channel 2 --start-s 2 --start-s 12 --start-s 22 --output /tmp/acoustics.json
```

Channels are zero-based. Reference windows default to 200 ms; maximum searched delay
is 600 ms. Pick window times with broadband reference energy. The standard-library
FFT matches normalized cross-correlation, handles polarity inversion and gain,
rejects silent/weak/ambiguous windows, and retains each selected window's delay and
correlation. Outputs nearest-rank latency percentiles and inter-listener skew. A
rejected window is not silently excluded from a success result. Missing/negative
delays outside the search range require correcting the capture/window setup.

Unit tests verify known 120/160 ms delays and 40 ms inter-listener skew. Those are
synthetic analyzer-validation measurements, not phone performance. Selected windows
do not establish whole-run continuity, loss rate, thermal behavior or qualification.

## Framed-stream faults

```sh
python3 scripts/gateway_fault_proxy.py /path/to/fault-plan.json --target-port 50000 --duration-s 30 --output /tmp/fault-trace.json
```

The listener and destination are loopback-only, one connection, with bounded lifetime.
It prints the chosen listener port. The integration test must explicitly connect
through it; production routes do not enable it automatically. Fault plan:
`{schema: 1, seed: UINT32, faults: [{direction: upstream|downstream, record: POSITIVE_INT,
operation: delay|block|eof|corrupt|duplicate|malformed, milliseconds: INT}]}`.
`milliseconds` applies only to delay/block and is bounded to 30 seconds. Blocking
stops consuming that direction temporarily, allowing actual socket backpressure.
The proxy caps records at 256 KiB, preserves complete records and hop ACKs by default,
and logs hashes rather than payloads. Corruption deliberately changes authenticated
bytes; native receivers must reject them. Stale callback/generation faults belong in
native lifecycle unit tests; this proxy does not simulate them or radio behavior.
