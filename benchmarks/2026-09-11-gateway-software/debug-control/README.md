# Debug control component evidence

Date: 2026-09-11. Device: `emulator-5554`. This is emulator application-control
evidence, not physical USB, Wi-Fi Aware, Apple peer-to-peer or acoustic qualification.

Commands executed, with output directories preserved:

```sh
python3 scripts/verify_gateway_android_debug.py --install --output /tmp/GetOverHereGatewayDebugAdapter-3
python3 scripts/verify_gateway_android_control_ui.py --grant-microphone --output /tmp/GetOverHereGatewayDebugUI-3
python3 scripts/verify_debug_control_release.py Android/app/build/outputs/apk/release/app-release-unsigned.apk
python3 -m unittest discover -s scripts -p 'test_gateway_tools.py' -v
```

The adapter runner externally read installed app/test APK SHA-256 and compared
them with the selected local build. Exact hashes are in `adapter-manifest.json`.
The UI run immediately followed on those installed APKs; it did not install or
replace the app. Release exclusion passed on APK SHA-256
`911c05b05a06bd83b522fc33d17630b005a88f734c593b7aa81ca645145b3fb8`.

Observed results:

- Native endpoint instrumentation: 3/3 passed, no skipped tests. Actual application
  status over pinned TLS/HMAC; wrong HMAC rejected; replay and unknown command rejected.
- Visible UI consent, Python client and local recorder: PASS. The app entered
  guide `RUNNING`, remained in the same room for eleven samples over 10,019 ms,
  and passed 22/22 actual same-room/active checks. No listeners were attached.
- Host verification suite: 36/36 passed, including real localhost fault-proxy I/O
  and explicitly artificial analyzer/manifest/native-format fixtures.
- Cleanup: no errors. Follow-up ADB checks confirmed private credentials absent,
  forwarding table empty, microphone permission restored to its original false.

The recording explicitly reports `RECORDED_NOT_QUALIFIED`. Capture/renderer
progress does not establish audio delivery: this no-guest run reports zero sent
frames and zero accepted playback bytes. `RUNNING` is an observed application
state, not an acoustic result. The native trace contains random app/room/run IDs,
not admission codes, credentials, enrollment keys or microphone samples.

Earlier UI attempts remain failures, not overwritten: `/tmp/GetOverHereGatewayDebugUI-1`
failed because UIAutomator produced no hierarchy file. `/tmp/GetOverHereGatewayDebugUI-2`
failed before enabling control because the runner raced activity presentation and
matched mixed-case text against Android's uppercase button rendering. The final
runner waits for activity launch, matches the observed label case-insensitively,
and retains hierarchy/failure/cleanup output. No physical run was substituted.

Retained-file hashes (the native summary has one trailing newline added by the
repository patch; its unchanged original-byte hash was
`4efbfd42ed6ff78ebddcc7535de061c9bf7267755d9eea0527b23c091c0d178d`):

| File | SHA-256 |
| --- | --- |
| `instrumentation.log` | `70f41d19f650c871a07e92ca0d4404f417367feaff16ea089639754a762ee944` |
| `native-observations.jsonl` | `e3bbce29cceb1da7f879913212b83fa39e2da5f80a944dcb764dbaae4946db95` |
| `native-summary.json` | `19901e168342fcbfecf74a64271063c23cf6fc0ef55f3f282d2c210c358df769` |
| `ui-result.json` | `2fa90bc688e22c0e08f1fc984cf1d81c71c7dd40de4e4b0b0cb8979db026506d` |
| `cleanup.json` | `339acc3b09add3c3d0e689adf17878a1bd264d3a3f00fccce7db538630e20066` |
