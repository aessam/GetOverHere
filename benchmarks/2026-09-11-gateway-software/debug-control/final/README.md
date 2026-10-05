# Post-fix debug control evidence

Date: 2026-09-11. Emulator: `emulator-5554`. Earlier native3/UI22 reports are
preserved in the parent directory. These runs verify the final debug startup and
cleanup changes; they do not replace physical transport or acoustic qualification.

```sh
python3 scripts/verify_gateway_android_debug.py --output /tmp/GetOverHereGatewayDebugAdapter-4
python3 scripts/verify_gateway_android_control_ui.py --grant-microphone --output /tmp/GetOverHereGatewayDebugUI-4
```

The Android owner had installed the final app/test APKs. The first command read
their actual installed SHA-256 and matched the local artifacts before executing:

- App: `320831ef1af0610425a5190e7a6c9916c1245d7fde84e125dc57a9c2d20f5918`
- Test APK: `b396159d016269add61da846461c9c7b237ed62737b4da3343cacbcda9218011`

Native tests: **5/5 passed, zero skipped**. The original three checks cover actual
app status over pinned TLS/HMAC, wrong-HMAC rejection, and replay/unknown-command
rejection. The two additional deterministic component regressions use a real TLS
listener: an injected close IOException cannot skip key/credential/executor cleanup;
a latch holds startup before publication so Stop wins, then late publication must
fail with the unpublished socket closed and credentials absent. These injected
component faults are not physical device measurements.

Visible-consent/client/recorder smoke: **PASS**, with **22/22 same-room and active
checks** from eleven native samples over **10,033 ms**. No listeners were attached;
zero frames were sent and zero playback bytes accepted. Observing `RUNNING` does
not prove delivered voice or acoustic quality. The native summary remains
`RECORDED_NOT_QUALIFIED`.

The UI runner reported no cleanup errors. Follow-up read-only ADB checks confirmed:
`run-as ... test -f files/debug-control/credentials.json` returned 1 (absent),
`adb forward --list` was empty, and `RECORD_AUDIO: granted=false` restored the prior
permission. The emulator was handed back to the root agent for the separate TLS
interoperability test. No physical phones were probed or changed.

Retained evidence SHA-256:

| File | SHA-256 |
| --- | --- |
| `instrumentation.log` | `e070903a808e285b1d7175d745eecfafffa04d50df4a403e13a27cd4c4ab61be` |
| `native-observations.jsonl` | `910238ecfcb45073b0b3275d229b2dd204f4e9e182f8e125f21390c57dc204f6` |
| `native-summary.json` | `bd1dc188ee01ebd709247d679bb8c43159eef349bffa85a92edcbb78535933db` |
| `ui-result.json` | `2fa90bc688e22c0e08f1fc984cf1d81c71c7dd40de4e4b0b0cb8979db026506d` |

The repository patch adds one trailing newline to the otherwise unchanged native
summary. Its original-byte hash is
`3b6e85d0b4a7874e753531d9bfd3a358cfbfb6d0c4f83c1ddd7528b7623570c0`.

The existing Release APK still passes debug exclusion, but its hash remains the
earlier `911c05b0…` artifact. This check alone does not establish that later production
source changes have been included in a fresh Release build.
