# Two-hub gateway software verification

September 11, 2026. Implementation started from `18d0c46` on
`fix/deep-dive-2026-09-02`. The coordinated software candidate passed; it is not a
physical gateway qualification report. The stable LAN tag is unchanged. This
directory is committed with the implementation; pre-commit observations correctly
record the starting revision and dirty tree, not a fabricated build attestation.

## Final software results

| Gate | Result | Scope |
|---|---|---|
| Main `verify_tour_session.sh` |9/9 stages, exit0|`integrated-final.log`; initial failed privacy/lint gates retained separately|
| Swift TourSessionCore |81 tests,13 suites,0 failures|Protocol/core behavior|
| Kotlin TourSessionCore |82 tests,13 suites,0 failures|Mirrored protocol/core behavior|
| LocalLinkSecurity |4 definitions,8 cases,0 failures|Real Apple TLS and certificate rejection|
| Android app JVM |198 tests,37 suites,0 failures/skips|Final guide/companion ownership, codec and existing app regressions|
| Android native |9/9,0 skipped|Actual TLS, admission isolation, address replacement, stale callback and interface-scoped mDNS callback|
| iOS app Simulator |196 definitions/242 runs passed;4 skipped|All app-unit selection; skipped cases are explicit device-only Bluetooth fixtures, listed below|
| iOS focused setup/recovery |9 definitions/10 runs,0 skipped|Includes actual production setup UI and stop/replacement security regressions|
| Android production setup UI |1/1|Actual MainActivity → Companion → interface inventory → Back, unchanged permissions|
| Host gateway tools |36/36|Runner validation, actual loopback, faults, acoustic known-delay analysis and evidence rejection|
| Android debug native |5/5|Actual TLS/HMAC, replay rejection, close-fault cleanup, late-start-after-stop|
| Android visible client/recorder |22/22 checks;11 samples/10,040ms|Final installed APK; real guide-state continuity, no listeners/audio-delivery claim|
| Gateway Swift/Kotlin parity |262/262,0 skipped|Ten exact fixtures; both decoders and malformed/QR rejection|
| Existing admission v1 parity |8/8 real exchanges|Both directions, open and locked|
| Existing admission v2 parity |8 exchanges+8 explicit rejections|Admission-bound guide key, signatures and AEAD|
| Existing guide signatures |8/8 each direction|Real signatures; changed/truncated packets rejected|
| Apple/Android TLS interoperability |2/2 server roles,0 skipped|Final installed APK hashes; production identity/TLS code;65,536 exact bytes per roundtrip over ADB|
| Builds / release security |PASS|Android lint/debug/test/release; signed iPhone build integrity; both Release debug-exclusion audits|

Android detail and build hashes: `android/summary.json`. Latest real debug/UI
evidence is `debug-control/coordinated-candidate/`; older directories retain
earlier candidates. Production setup evidence is `gateway-setup-ui/`.
iOS exact full-suite counts: `ios/full-unit-summary.json`. Its four skipped
fixtures are BluetoothChannelProbeTests/nativeChannelsOpenOnOnePeripheral,
NearbyLiveSessionTests/productionSessionDeliversLiveAudioAndReadinessOverBluetooth,
NearbyPhysicalTransportTests/bluetoothCarriesAdmissionControlAssetsAndNativeAudio,
and BluetoothSpeedTests/measure. None is counted as physical evidence.

Xcode emitted three compiler-driver diagnostics saying exit0/no further output,
but the completed xcresult reports Passed, zero failures and the positive counts
above; the enclosing command exited0. No speculative source fix was made for
those diagnostics. Existing Swift-concurrency migration warnings remain visible
in the retained log; this report does not claim a warning-free build.

Commands:

```sh
DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer \
GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer \
GOH_ANDROID_JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
GOH_SWIFT_SCRATCH=/tmp/GetOverHereGatewayParitySwift \
GOH_LINK_SECURITY_SCRATCH=/tmp/GetOverHereTourSessionLinkSecurity \
GOH_IOS_DESTINATION='platform=iOS Simulator,id=5CCA0393-1F29-47F3-AC23-CBE1C99533F4' \
GOH_IOS_DERIVED_DATA=/tmp/GetOverHereGatewayIntegratedDerived \
bash scripts/verify_tour_session.sh
```

Raw protocol cases are retained in `protocol.json`. The first Swift gateway run
caught a test's size arithmetic error (171 expected,172 actual); correcting that
expectation left the wire unchanged. A zero-selected-test invocation before the
test file existed is not counted. One full-core attempt failed on sandboxed
compiler cache access; the authorized rerun passed.

TLS compatibility command:

```sh
python3 scripts/verify_gateway_tls_interop.py \
  --serial emulator-5554 --adb /Users/aessam/Library/Android/sdk/platform-tools/adb \
  --binary Packages/GatewayTLSFixture/.build/out/Products/Debug/gateway-tls-fixture \
  --apk Android/app/build/outputs/apk/debug/app-debug.apk \
  --test-apk Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk \
  --output /tmp/GetOverHereGatewayTLSInterop-final
```

`tls-interop-final/result.json`, `preflight.json` and adjacent native logs retain
both roles, installed hashes and scoped tunnel/key cleanup. `tls-interop/` retains
the first successful run before installed-artifact checking was added. Android's
production key manager needed engine alias
callbacks and DIGEST_NONE authorization; the initial native failures were not
papered over with a test-only certificate implementation. Payload SHA-256 at
both endpoints: `4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2`.

## Physical gates

NOT RUN: application USB traffic, USB/radio coexistence, guide and companion in
both physical orientations, locked listeners, acoustic timing, presentation/assets
through both radio branches, disconnect recovery, group capacity and endurance.
Saved wireless ADB endpoints were unavailable during implementation. The existing
USB ICMP and earlier Aware/Bluetooth benchmarks do not satisfy these gates.

Apple Network.framework and AndroidKeyStore/JSSE interoperability over ADB, when
run, is a software compatibility test only. Neither the emulator nor a simulator
establishes USB Ethernet routing or native radio behavior.
