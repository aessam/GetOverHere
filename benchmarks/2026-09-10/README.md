# Three-phone transport benchmark — 10 September 2026

Physical devices: iPhone 12 mini (iOS 26.5.2), Pixel 11 Pro and Pixel 7 (both Android 17/API 37).
The user forgot the iPhone's infrastructure Wi-Fi network before these runs.
Device control used USB. Mixed measurements used Bluetooth L2CAP, not LAN or
mixed-platform Wi-Fi Aware. Radios were not changed by the benchmark runners.

## Bluetooth results

Median application-payload Mbps from three verified 64 KiB transfers per direction.
RTT uses 50 byte-verified 64-byte echoes, measured on the initiating guest's monotonic
clock. Rates are decimal megabits/s, not MB/s. Nearest-rank percentiles.

| Guide | Guest | Guide → guest Mbps | Guest → guide Mbps | Idle RTT p50 / p95 ms |
|---|---|---:|---:|---:|
| iPhone | Pixel 11 Pro | 0.532 | 0.464 | 32.5 / 35.7 |
| Pixel 11 Pro | iPhone | 0.253 | 0.278 | 60.2 / 62.4 |
| iPhone | Pixel 7 | 0.529 | 0.462 | 30.5 / 45.8 |
| Pixel 7 | iPhone | 0.257 | 0.273 | 60.1 / 62.6 |
| Pixel 11 Pro | Pixel 7 | 0.160 | 0.104 | 30.8 / 37.6 |
| Pixel 7 | Pixel 11 Pro | 0.652 | 0.477 | 31.3 / 36.1 |

Every row passed in both endpoint test runners. Each JSON file contains all transfer
measurements and raw RTT samples. Results vary with the guide role; the cause has not
been isolated. This is one short session per role, not a device-family guarantee.

### iPhone with both Android listeners

| Guest | Guide → guest median Mbps | Guest → guide median Mbps | RTT p50 / p95 ms |
|---|---:|---:|---:|
| Pixel 11 Pro | 0.216 | 0.355 | 32.6 / 59.4 |
| Pixel 7 | 0.465 | 0.429 | 30.6 / 45.8 |

Both native connections were served concurrently; each guest independently advanced
through ping/download/upload phases. This was not a synchronized multicast/fan-out
trial, and summing their medians is not a measured aggregate bitrate. The uneven
per-guest results need longer synchronized trials before any group-capacity claim.

## Android Wi-Fi Aware

Initial bulk pilot: 3 seconds per direction, one measured round per guide role,
plus duplex and separate warm-up. One-way observed range 285–302 Mbps; simultaneous
duplex 182–191 Mbps per direction. Idle RTT p95 154–164 ms, loaded p95 189–233 ms.
Raw results: `android-aware-bulk.json`. The pilot's manifest captured its test-APK
hash before the new Bluetooth test build completed, so use the subsequent hash-verified
repeated run for final binary provenance; the Aware benchmark implementation did not change.

Small-packet test: three 3-second rounds per condition and guide orientation, 50
packets/s, synthetic codec-sized bytes with production AEAD/signature framing.
Conditions: idle and paced asset traffic (524,288 bytes/s target).
All 1,800 echoes returned; no local schedule drops. 176 echoes had RTT ≥150 ms.
These are late round trips, not lost packets or measured one-way/audio delays.
Raw samples and per-trial counters: `android-aware-tiny.json`.

Repeated bulk: three 5-second trials per mode and guide orientation, with a separate
warm-up. Both roles completed, all sender/receiver byte counts matched, and installed
APKs were verified against their build hashes before running.

| Guide | Guest | Guide → guest median Mbps | Guest → guide median Mbps | Duplex median Mbps, out / back |
|---|---|---:|---:|---:|
| Pixel 11 Pro | Pixel 7 | 316.46 | 282.70 | 182.41 / 183.61 |
| Pixel 7 | Pixel 11 Pro | 304.39 | 304.65 | 195.31 / 188.34 |

Per-trial loaded RTT p95 ranged 176.8–241.8 ms. Both Androids reported eight maximum
data paths and seven available after this single peer connected. Four logical sockets
used one observed native Network per endpoint. This is device-specific resource
evidence, not eight or thirty qualified listeners. Results: `android-aware-repeated.json`;
build/run provenance: `android-aware-manifest.json`.

## Scope and limitations

- GBB1 is a test-only synthetic byte protocol through the production Bluetooth
  connection and guide-side loopback adapter. No tour admission, AEAD, signing or
  codec overhead is included in its bitrate. Every received payload is compared
  byte-for-byte, with receiver timing and completion acknowledgments.
- Bulk Aware uses verified synthetic blocks over TCP and the guide adapter; tiny
  Aware uses real application framing but synthetic audio bytes. Neither is native
  UDP or acoustic measurement.
- A 16 KiB mixed pilot passed before the 64 KiB matrix. Android and iOS socket-loopback
  protocol tests each passed 1/1. The first iOS selector ran zero tests and was rejected;
  the corrected Swift Testing identifier includes `()` and passed 1/1.
- No 30-phone, outdoor movement, locked-screen, thermal/battery endurance, packet-loss
  radio measurement, or microphone-to-speaker latency claim follows from these results.
- Earlier real tour UI runs passed both Bluetooth directions after forgetting Wi-Fi,
  but an intermittent Android-guide audio startup failure and encoder-recreation churn
  remain separate unresolved product issues. Speed-test success does not close them.

## Reproduce

Build the current Android debug app/test APKs and signed iPhone test bundle first.
Run the new Android `BluetoothSpeedTest#protocolSmoke` and iOS
`BluetoothSpeedTests/protocolSmoke()` before physical trials. No simulator radio result
is counted. The Aware runner includes its own emulator smoke gates.

```sh
export DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer
python3 scripts/benchmark_three_phones.py --ios 00008101-000C690C3A30001E --android 66180DLKX006ND 2A111FDH2007A1 --manifest /tmp/GetOverHereDebugApp20260910/Build/Products/GetOverHere_GetOverHere_iphoneos27.0-arm64.xctestrun
python3 scripts/benchmark_android_bluetooth.py --guide 66180DLKX006ND --guest 2A111FDH2007A1
python3 scripts/benchmark_android_aware.py --guide 66180DLKX006ND --guest 2A111FDH2007A1 --profile tiny --millis 3000 --rounds 3 --reuse-installed
python3 scripts/benchmark_android_aware.py --guide 66180DLKX006ND --guest 2A111FDH2007A1 --millis 5000 --rounds 3 --reuse-installed
```

Raw full-run folders: `/tmp/GetOverHereThreePhones.t3nde1f7`,
`/tmp/GetOverHereAndroidBluetoothSpeed.1c0rrfh2`,
`/tmp/GetOverHereAwareBenchmark.zicic5jv`, `/tmp/GetOverHereAwareBenchmark.fg9h6qy1`; the matrix log points to each xcresult
and Android instrumentation log. JSON measurements are retained here in the repo.

Measured working tree started at `63bb77d`, including the pending GOL2 and iOS listener
fixes. Android app SHA-256: `1696c5a1a10bdd17241b6ee18228845122fd9c2bf9d57050b4dbe57a17b63252`;
test APK: `de8f8c7966040b4450987ed535c63455dbdd4dc48818f7694eb9d822e61b4614`.
iPhone production debug dylib: `0e54afdb60623941432387c0539a80086db5f29375d96b385ca0bf688289f829`;
test executable: `ab7365b0ebce29478532d6bacf2cc957f1132e09b03291c65b857e7d528cd8bb`.
