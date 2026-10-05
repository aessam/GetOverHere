# Evidence for CodeReview-2026-09-22.md

Commit `b820aaf`, macOS 27.0, Xcode at `xcode-select -p`. No physical devices used.
Swift repros under `repro/` depend on the local `Packages/TourSessionCore` by absolute path.
To run one: create `Sources/<Name>/main.swift` next to its `Package.swift`, then run `swift run -c release`.

## Gate

| Command | Result | Log |
|---|---|---|
| `scripts/verify_tour_session.sh` | Steps 1–8 pass. Step 9 fails with exit 70 because no `iPhone 17 Pro` simulator is installed. | `logs/verify_tour_session.log` |
| Step 9, using the script's exact xcodebuild command with `-destination "platform=iOS Simulator,name=iPhone 17 Pro Max"` | Passed: 248 passed, 0 failed, 4 skipped. Taken from the xcresult summary, iOS 27.0. | `logs/ios_step9_iphone17promax.log` |

## Repros

| Finding | Source | What it drives | Observed output |
|---|---|---|---|
| FND-1 | `repro/jitter-replacement/` | The real Swift-core `EncodedAudioJitterBuffer`. Sends 90,000 frames, then restarts the sequence at 0. | `after replacement: 3000 frames offered, duplicate=3000, played=2` |
| FND-2 | `repro/jitter-drift/` | The real buffer, with the guest clock set to ±ppm and a 4 h run. | `ppm=100 firstSilentAfterMin=76.7`<br>`ppm=40 191.7`<br>`ppm=-40 never` |
| FND-3 | `repro/shared-opener/` | The real `SessionFrameSealer`/`SessionFrameOpener`. Guest A forges a frame as guest B, and B's next real frame is then rejected. | `B seq2 rejected: session frame fell outside replay window` (output reported by the lane agent, not re-run here) |
| FND-11 | `repro/mapstyle/main.swift` | A standalone copy of iOS `OfflineMapPack`. Its `rejectRemoteResource` is byte-identical to production, checked with `diff`. Build with `swiftc main.swift`. | geojson_data, pmtiles_https, sprite_array and protocol_relative are ACCEPTED. The plain_https control is rejected. |
| FND-14 | `repro/bom/bom.swift`, `Bom.java`, `t.jsh` | Swift `String(data:encoding:.utf8)` compared with the Java `CharsetDecoder` on bytes `EF BB BF 41`. | Swift returns scalars `["41"]`, Java returns length 2 starting with `feff`. |
| FND-14/15 | `repro/bom/cli_cases.hex`, `asset_offset_envelope.py` | GOH2 envelopes fed to the real `tour-session-swift` and `tour-session-cli` decode commands. | For the BOM slide, Swift gives `slide=67617465` and Kotlin gives `efbbbf67617465`. For offset `ffffffffffffffff`, Swift accepts it and Kotlin fails with `Failed requirement.` (lane agent output) |
| FND-9 | `repro/asset-isolation/iso.swift` | A minimal class with no isolation annotation, compiled with the project's default MainActor isolation flags. | Reported `Thread.isMainThread == true` (lane agent output) |

The ppm values are assumed crystal tolerances, not measured on these devices.
`lane-findings-raw.md` holds the six lanes' findings before the red-team pass. The report's severities come after the red-team pass.
