# Production companion-screen smoke

2026-09-11, `emulator-5554`, Android 16/API 36. **1/1 passed, zero skipped**.
This is the actual production `MainActivity` and `GatewayScreen`, not the debug
consent screen or a screen composed with fabricated service data.

Executed through the existing `device_lock` and bounded `execute` helpers, with
a 90-second process deadline and the test's 30-second method deadline:

```sh
adb -s emulator-5554 shell am instrument -w -r -e class com.aessam.comeoverhere.GatewaySetupUITest com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner
```

The preflight independently compared installed APK SHA-256 with the local artifacts:

- App: `33e39ffd688c3be3dfea7a2bbd626edbe55b48e5532bde6da4170523cf51f64a`
- Test APK: `ee4a6e7bda175c5877ca3edeafc1308fcc8e575c95f9d820ac095b48bf496d9c`

The single test verifies idle state, taps the visible Companion action, checks
`gatewayStatus`, awaits actual service interface enumeration, and checks visible
guide/scanning action availability against that real inventory. Back returns to
the room screen. Permissions are compared before/after; the prior screen-awake
flag is verified and restored. No fake tour/interface, pairing operation, camera
launch, radio grant or microphone grant is used by this test. Rule teardown closes
its activity. Test duration in the native report: 5.395 seconds.

The emulator's network inventory is retained as observed data, not evidence of a
physical cable or Wi-Fi Aware connection. This test does not qualify forwarding,
pairing, screen-locked audio, acoustic quality or group capacity.

Raw native log SHA-256:
`aa5d04699b9df3de3dd720138d396b3b4ce2e6ec5b069bfbaf43fc4527111c4d`.
The exact command, OS and externally verified artifacts are in `manifest.json`;
`result.json` records the nonzero, unskipped result.
