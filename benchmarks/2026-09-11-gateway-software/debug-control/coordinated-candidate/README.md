# Debug checks on the coordinated Android candidate

2026-09-11. Both checks ran after the production companion-screen smoke, on the
same externally verified installed app/test APKs:

- App: `33e39ffd688c3be3dfea7a2bbd626edbe55b48e5532bde6da4170523cf51f64a`
- Test APK: `ee4a6e7bda175c5877ca3edeafc1308fcc8e575c95f9d820ac095b48bf496d9c`

```sh
python3 scripts/verify_gateway_android_debug.py --output /tmp/GetOverHereGatewayDebugAdapter-5
python3 scripts/verify_gateway_android_control_ui.py --grant-microphone --output /tmp/GetOverHereGatewayDebugUI-5
python3 scripts/verify_debug_control_release.py Android/app/build/outputs/apk/release/app-release-unsigned.apk
```

Native debug component tests: **5/5 passed, zero skipped**, including the two
deterministic shutdown/startup fault regressions. Visible consent, real client,
guide runtime and native recorder: **PASS; 22/22 same-room/active checks**, eleven
samples over **10,040 ms**. No listeners were attached, and this is not delivered
voice, physical transport or acoustic qualification. The native recorder correctly
retains `RECORDED_NOT_QUALIFIED`.

Cleanup completed without errors. Follow-up ADB checks confirmed private debug
credentials absent, forwarding table empty, and microphone permission restored to
its prior false state. The production setup-screen test itself granted no
permissions; only this explicitly requested emulator capture smoke temporarily
granted and restored microphone access. The emulator was released to the root
agent for its separate final TLS interoperability run.

Fresh Release artifact `d37e8b599b8f5002bea767e6aaa164f3c6d826d7afa1d3ce6ce0511441995af8`
passed manifest/DEX debug exclusion. Earlier candidate reports remain preserved in
the parent and `final` directories; they are not relabeled as this candidate.

Retained hashes:

| File | SHA-256 |
| --- | --- |
| `instrumentation.log` | `0c3d52c5f6e0fe12aaacf3e849602ca40328059db53e8deacab16ce373cffb75` |
| `native-observations.jsonl` | `e3922d65b12d1db9539d5baf20c5e7582a5c4d20db51498f35be5a2a3d9a3319` |
| `native-summary.json` | `b10390ee4ee2f43268048989be559e81a3210eb3231593e483721c9611d10364` |

The repository patch adds one trailing newline to the otherwise unchanged native
summary; its original-byte hash is
`d9bcc8a13177e99c1c0d2bcfdf2f383df0486b96b0ad8868d9d67208cb658b4e`.
