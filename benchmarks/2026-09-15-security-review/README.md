# September 15 gateway review and repair evidence

Branch: `fix/deep-dive-2026-09-02`. Original reviewed implementation: `ec1b0b8`.
The commit containing this evidence repairs F1–F12 in
[`SecurityCodeReview-2026-09-15.md`](../../SecurityCodeReview-2026-09-15.md).
Physical phones were not queried or used. This is a software candidate, not
USB/radio, acoustic, lock, thermal, battery or 30-listener qualification.

## Executed gates

| Gate | Result / retained evidence |
|---|---|
| Main `verify_tour_session.sh` | All 9 stages pass; `full-gate.txt` |
| Swift core | 84 definitions pass; main gate log |
| Kotlin core | 83 tests, 0 failures/errors/skips; `final-android-units.txt` and Gradle XML |
| Android app unit | 205 tests / 37 suites, 0 failures/errors/skips; normal sources restored after review injection |
| iOS app simulator | 201 definitions / 248 parameterized runs pass; 4 hardware-only skips; `ios-unit-summary.json` |
| iOS setup and debug deeplink UI | 2/2 pass, no skips; `ios-ui-summary.json` |
| Original red review regressions | Swift 1/1, Android 3/3 now pass; `*-reproductions-fixed.txt`; original red logs preserved |
| Gateway wire parity | 10 exact fixture lines, 262/262 roundtrip/rejection cases; no wire format change |
| Admission/signatures | v1 8 real exchanges; v2 8 exchanges + 8 rejection cases; signature parity and encrypted-path audit pass |
| Host tooling | 12 benchmark-guard tests and 36 gateway-tool tests pass; main gate log |
| Native Android gateway faults | 12/12 pass, no skips; `native-gateway-tests.txt` |
| Native Android codec/reconnect | 8/8 pass, no skips; `native-audio-tests.txt` |
| Actual Android setup UI/debug adapter | 6/6 pass, no skips; `android-ui-debug-tests.txt` |
| Visible consent → real network client → local recorder | 22 checks pass; `control-ui-result.json`; cleanup errors empty |
| Mac Network.framework ↔ AndroidKeyStore TLS | Both server orientations pass; each round-trips 65,536 exact bytes; `tls-interop.json` |
| LocalLinkSecurity | 6 definitions / 10 cases pass, including stored Keychain renewal and invalid/expired/missing peer TLS rejection |
| Android and iOS Release | Both build; `verify_debug_control_release.py` passes for each |
| Generic signed iPhone Debug | Build passes; `codesign --verify --deep --strict` exits 0; not installed on a phone |

Four explicit iOS device-only skips remain the Bluetooth channel, live-session,
physical-transport and speed fixtures. No hardware test was relabeled as a pass.
Native codec failure/stall recovery tests inject the provider failure; native
emulator codec tests separately exercise MediaCodec. Neither proves acoustic
quality or real thermal codec reclamation.

## Reproduce

Run from the repository root, with Xcode at
`/Users/aessam/Downloads/Xcode.app/Contents/Developer`, Java at
`/Applications/Android Studio.app/Contents/jbr/Contents/Home`, and ADB at
`/Users/aessam/Library/Android/sdk/platform-tools/adb`.

```sh
DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer \
GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer \
GOH_ANDROID_JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
GOH_SWIFT_SCRATCH=/tmp/GetOverHereGatewayParitySwift \
GOH_LINK_SECURITY_SCRATCH=/tmp/GetOverHereTourSessionLinkSecurity \
GOH_IOS_DESTINATION='platform=iOS Simulator,id=5CCA0393-1F29-47F3-AC23-CBE1C99533F4' \
GOH_IOS_DERIVED_DATA=/tmp/GetOverHereGatewayReviewDerived \
bash scripts/verify_tour_session.sh

DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer \
bash scripts/review/gateway/run.sh
```

The review runner injects extra Android test sources only for that invocation.
Afterward run `:app:testDebugUnitTest :tour-session-core:test` without its init
script to restore the ordinary Gradle test-source state. The final run did this.

Native gateway tests require the local `GetOverHere_API_36` emulator, installed
current Debug and androidTest APKs, and no concurrent instrumentation:

```sh
/Users/aessam/Library/Android/sdk/platform-tools/adb -s emulator-5554 shell am instrument -w -r \
  -e class com.aessam.comeoverhere.WiredHubTLSIdentityTest,com.aessam.comeoverhere.WiredGatewayAdmissionTest,com.aessam.comeoverhere.WiredRecoveryNativeTest \
  com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner
```

Other executed class groups were
`NativeRealtimeAudioCodecTest,NativeAudioCodecCapabilitiesTest,AudioLaneReconnectTest`
and `GatewaySetupUITest,GatewayDebugControlTest` in the same package/runner.
ADB's exit status alone is insufficient: require `OK (N tests)` and no failed or
skipped instrumentation results. These three logs retain that evidence.

Cross-runtime TLS command:

```sh
DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer swift build --disable-sandbox --package-path Packages/GatewayTLSFixture
python3 scripts/verify_gateway_tls_interop.py --serial emulator-5554 \
  --adb /Users/aessam/Library/Android/sdk/platform-tools/adb \
  --binary Packages/GatewayTLSFixture/.build/out/Products/Debug/gateway-tls-fixture \
  --apk Android/app/build/outputs/apk/debug/app-debug.apk \
  --test-apk Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk \
  --output /tmp/GetOverHereGatewayReview-tls-interop-NEW
```

The native UI/client recorder uses
`python3 scripts/verify_gateway_android_control_ui.py --device emulator-5554 --adb /Users/aessam/Library/Android/sdk/platform-tools/adb --grant-microphone --output /tmp/GetOverHereGatewayReview-control-ui-NEW`.
It closes its test room/debug endpoint and restores its granted permission.
It does not establish live audience playback.

## Frozen artifacts

| Artifact | SHA-256 |
|---|---|
| Android Debug `Android/app/build/outputs/apk/debug/app-debug.apk` | `c2ea45e02ffd401a7f326d2f4af66f931db721c7764ea1685ff27f1b2d558426` |
| Android test APK `Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk` | `92339a00aaf7132423c4c6048dae531abd56cd4db18d2a118ce059b55e4b3c73` |
| Android unsigned Release APK | `8331ef4d8d85078bb3b21b49a01a871fa2ba5ab6b06f09a058dbf593c6bf591d` |
| Signed iPhone Debug main executable | `5ab9ffbaad254fa961cf080b343f5697f386cd56fcf8bd4e554030d3c2e10586` |

iPhone app:
`/tmp/GetOverHereGatewayReviewDevice/Build/Products/Debug-iphoneos/GetOverHere.app`.
Its executable hash identifies that file, not a deterministic hash of the whole
signed bundle. iOS Release exclusion checked
`/tmp/GetOverHereGatewayReviewRelease/Build/Products/Release-iphoneos/GetOverHere.app`.

Final simulator result:
`/tmp/GetOverHereGatewayReviewDerived/Logs/Test/Test-GetOverHere-2026.09.15_08-43-41--0700.xcresult`.
UI result: `/tmp/GetOverHereGatewayReview-ui.xcresult`.

## Failures retained and remaining boundary

The first ad-hoc parallel iOS run stalled with networking failures and was
canceled; raw log `/tmp/GetOverHereGatewayReview-1.log` remains. It is not a pass
or a diagnosed production failure. The first prescribed serial run failed one
old assertion expecting immediate companion expiry; result at
`/tmp/GetOverHereGatewayReviewDerived/Logs/Test/Test-GetOverHere-2026.09.15_08-39-35--0700.xcresult`.
The assertion now tests beyond the explicit 30s allowance; guide-side strict
expiry remains independently tested. The final complete serial run passed.

Existing compiler/deprecation warnings remain, including Swift actor-isolation
warnings outside the repair and Android SDK 37.2/AGP compatibility warnings.
No warning-free, fuzz-complete or physical readiness claim is made.
Next: `FieldAcceptance.md` A13–A20 on the approved two-hub topology when the user
returns with devices. Preserve `stable-local-network`; do not retag it.
