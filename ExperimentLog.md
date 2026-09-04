# Experiment Log

## 2026-08-21 — Native Wi-Fi Aware lab baseline

Environment:

- Host: Apple M4 Max, macOS
- Xcode: `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer`, Xcode 27.0
- iPhone: iPhone 17 Pro Max, iOS 27.0, UDID `00008150-001208901AC0401C`
- Android: Pixel 11 Pro, Android API 37, serial `66180DLKX006ND`
- Android SDK: `/Users/aessam/Library/Android/sdk`

Commands and results:

1. `xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'generic/platform=iOS' -derivedDataPath /tmp/GetOverHereDerived CODE_SIGNING_ALLOWED=NO build`
   - Result: pass after implementation. Existing unrelated Swift concurrency warnings remain.
2. `xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/GetOverHereDerived test -only-testing:GetOverHereTests/WiFiAwareProbeFrameTests`
   - Result: 2/2 pass. Exact cross-platform fixture and truncated-payload rejection pass.
3. `cd Android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest`
   - Result: pass.
4. `cd Android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew assembleDebug`
   - Result: pass.
5. `adb -s 66180DLKX006ND install -r Android/app/build/outputs/apk/debug/app-debug.apk`
   - Result: success.
6. `adb -s 66180DLKX006ND shell dumpsys wifiaware`
   - Result: Wi-Fi Aware enabled; pairing supported; maximum NDP sessions 8; maximum publish sessions 8; maximum subscribe sessions 8; pairing cipher suites reported.
7. Signed generic iOS build without provisioning updates.
   - Result: failed because `iOS Team Provisioning Profile: com.aens.GetOverHere` lacks the Wi-Fi Aware capability and entitlement.
8. Signed generic iOS build with `-allowProvisioningUpdates`.
   - Result: failed with `No Accounts: Add a new account in Accounts settings`; profile could not be refreshed.
9. Physical iPhone destination build.
   - Result: device detected but development services were unavailable while the iPhone was locked.
10. `./scripts/verify_wifi_aware_lab.sh`
   - Result: pass. Unsigned iOS device compile, 2/2 focused iOS wire tests, Android unit tests, and Android debug APK build all passed.
11. Android publisher NDP port-advertisement review.
   - Result: fixed the publisher network specifier to advertise its bound UDP port and `IPPROTO_UDP`; Android unit tests and APK build passed afterward.
12. `adb -s 66180DLKX006ND install -r Android/app/build/outputs/apk/debug/app-debug.apk`
   - Result: latest corrected APK installed successfully.
13. Signed physical-iPhone build with `-allowProvisioningUpdates`.
   - Result: pass. Xcode refreshed profile `5bc7db2b-1c49-4ee2-b0b4-a941802c05cb`; the signed app contains `com.apple.developer.wifi-aware = [Publish, Subscribe]`.
14. `xcrun devicectl device install app --device 00008150-001208901AC0401C /tmp/GetOverHereWiFiAwareSigned/Build/Products/Debug-iphoneos/GetOverHere.app`
   - Result: installed successfully on Dark knight.
15. Physical app launch preflight.
   - Result: both phones were connected, but the iPhone rejected remote launch because it was locked and the Pixel UI hierarchy remained on its lock screen.

Physical cross-platform discovery, pairing, NDP, and 20 ms UDP probe remain unexecuted until both phones are unlocked.

## 2026-08-21 — Anti-feedback routing

Implementation:

- Listener output defaults to earpiece or connected headset on iOS and Android.
- Both listener screens expose a Speaker override and feedback warning.
- iOS enables voice processing for non-Bluetooth-HFP capture routes and logs any rejection.
- Android uses `VOICE_COMMUNICATION`, communication-mode routing, and reports actual AEC/NS enablement.

Commands and results:

1. `./scripts/verify_wifi_aware_lab.sh`
   - Result: pass. iOS unsigned device compile; 3/3 focused iOS tests; Android unit tests; Android debug APK build.
2. Android anti-feedback APK install.
   - Result: success on Pixel 11 Pro.
3. Signed iOS anti-feedback build and install.
   - Result: build artifact produced and installed successfully on Dark knight.
4. Two-phone speaker-versus-earpiece echo A/B.
   - Result: pending because both phones relocked before launch.
5. `cd Android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew connectedDebugAndroidTest`
   - Result: 3/3 physical Pixel tests passed. `listenerOutputSwitchesPhysicalCommunicationDevice` verified `PRIVATE_AUDIO` selects `TYPE_BUILTIN_EARPIECE` and `SPEAKER` selects `TYPE_BUILTIN_SPEAKER`; both route requests reported `applied=true`. `voiceCommunicationCaptureProducesAFrame` confirmed AEC and noise suppression enabled, capture started at 16 kHz, and a 640-byte float32 frame was emitted.

## 2026-08-21 — GOH2 session core and listener membership

Implementation:

- Added `Packages/TourSessionCore` with a library, Swift CLI, and Swift Testing suite.
- Added Android `:tour-session-core` and `:tour-session-cli` pure JVM modules; the Android app consumes the core directly.
- Linked the same Swift package to the iOS app and test targets.
- Added deterministic GOH2 hello, realtime audio, presentation snapshot, bearing snapshot, slide manifest, and asset chunk payloads.
- Replaced discovery-derived listener counts with a participant registry driven by validated GOH2 session hellos and socket disconnects.
- Converted the Android Wi-Fi Aware lab from singleton NDP state to per-peer discovery, callback, network, and UDP endpoint collections. Physical fan-out remains unverified.

Commands and results:

1. `swift test --package-path Packages/TourSessionCore`
   - Result: 9 tests pass, including golden bytes, wrong-lane rejection, truncation rejection, participant reconnect/scale, realtime fault accounting, presentation, bearing, manifest, and asset chunk roundtrips.
2. `cd Android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :tour-session-core:test :tour-session-cli:installDist`
   - Result: pass.
3. Swift/Kotlin CLI fixture comparison for hello, presentation, bearing, and slide manifest.
   - Result: exact encoded bytes and decoded values match.
4. Swift/Kotlin participant simulations at 1, 8, 20, and 50 guests.
   - Result: each reports `peak=N|reconnect=N|staleDisconnect=N|final=0`.
5. `cd Android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest assembleDebug`
   - Result: pass, including a real localhost TCP test for GOH2 hello membership and audio payload delivery.
6. Focused `xcodebuild test` on iPhone 17 Pro Simulator.
   - Result: pass, including the equivalent real localhost TCP GOH2 membership/audio test and package integration test.
7. Android target inspection.
   - Result: no connected Android device and no installed AVD were available for the post-change physical gate.
8. Product-flow cleanup.
   - Result: removed discovery-peer counters and audio-quality selection from both channel flows. The guide UI now exposes only the validated listener count; Wi-Fi Aware diagnostics remain confined to the lab.
9. `scripts/verify_tour_session.sh`
   - Result: all seven stages pass after the UI cleanup: Swift core tests, Kotlin core tests, exact cross-language fixtures, participant churn, realtime fault audit, Android app tests/APK, and focused iOS Simulator integration/TCP-loopback tests.
10. Physical-device install and launch smoke.
    - Pixel 11 Pro `66180DLKX006ND`: `adb install -r` returned `Success`; `MainActivity` launch returned `Status: ok`; process remained alive as PID `13512`.
    - iPhone 17 Pro Max `F043EBB9-780F-5483-B0D1-BC0BD9955D9C`: signed device build succeeded with provisioning profile `5bc7db2b-1c49-4ee2-b0b4-a941802c05cb`; `devicectl` installed and launched `com.aens.GetOverHere`; process remained alive as PID `19585`.

## 2026-08-21 — Tour target, control, and asset foundation

Implementation:

- Documented the complete privacy rule in `TourGuideProductSpec.md`: only the guide-selected target pin is transmitted. Guide and guest location, history, heading, accuracy, and movement are never wire fields.
- Added exact Swift/Kotlin target snapshots, local distance/bearing guidance, tour-pack manifests, asset requests, and asset readiness statuses.
- Added independent authenticated GOH2 control and asset sockets. Guide asset sends can target one participant.
- Added resumable file caches with length validation, streaming SHA-256 verification, and content-addressed final paths.
- Added a request-per-chunk transfer service with 65,536-byte chunks and per-participant readiness.

Commands and results:

1. `swift test -q` in `Packages/TourSessionCore`
   - Result: 12 Swift Testing tests pass, including 100 deterministic target-coordinate roundtrips.
2. `cd Android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :tour-session-core:test :tour-session-cli:installDist`
   - Result: pass.
3. Swift/Kotlin `state` CLI fixture comparison after target, tour-pack, request, and status additions.
   - Result: exact bytes match.
4. Focused Android `LocalSessionTransportTest`.
   - Result: pass for audio, bidirectional control, targeted asset manifest, and guest request loopbacks.
5. Focused iOS `LocalSessionTransportTests` on booted iPhone 17 Pro Simulator.
   - Result: 3/3 pass for the same audio/control/asset behaviors.
6. Focused `TourAssetCacheTest` / `TourAssetCacheTests`.
   - Result: both platforms resume at byte 7, verify the final checksum, reject corrupted bytes, delete the corrupt partial, and return to offset 0.
7. Focused `TourAssetTransferServiceTest` / `TourAssetTransferServiceTests`.
   - Result: both platforms resume a 150,000-byte asset at byte 65,536, finish through bounded chunks, reproduce the source bytes exactly, and report the guest ready to the guide.
8. Initial Xcode beta simulator run.
   - Result: compiled, but Xcode 26.5 clone launch failed with `NSPOSIXErrorDomain Code 3` and the test process hung during log finalization. Rerunning against explicitly booted simulator `05008420-7A8F-446E-924B-5D698E06F3C6` with a fresh derived-data path and CoreSimulator access passed. No app defect was found.

## 2026-08-21 — Complete tour UI, recovery, privacy, and lifecycle gate

Implementation:

- Added guide and guest slides UI backed by a versioned manifest, content-addressed cache, independent asset channel, verified resumable chunks, and authoritative presentation snapshots.
- Added imported offline PMTiles packs and local MapLibre rendering. Only the guide-selected target pin is transmitted. Device position, heading, accuracy, history, and derived movement remain local.
- Added a magnetic pointer. The guide shares one selected bearing; every guest rotates it using its own local heading.
- Added late-join and reconnect recovery for presentation, target, bearing, and cached-asset readiness.
- Added iOS background-audio configuration and privacy manifest. Added Android typed foreground service for guide microphone and guest playback.
- Removed the unused Google Nearby Connections Android dependency.

Commands and results:

1. `./scripts/verify_tour_session.sh`
   - Environment: `GOH_ANDROID_JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home`, `GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer`, `GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFinalVerificationDerivedData`.
   - Result: all seven stages passed: 12 Swift core tests, Kotlin core/CLI tests, exact Swift/Kotlin bytes, cross-decoding and participant churn, realtime fault and privacy audits, Android unit tests/APK, and the complete iOS unit suite.
2. Focused late-join and reconnect tests on both platforms.
   - Result: the same current presentation, target pin, and bearing snapshots are restored exactly. Rejoining with a verified cached asset re-reports readiness without duplicating the participant.
3. Interrupted asset tests on both platforms.
   - Result: a 150,000-byte asset resumes at byte 65,536, survives guest disconnect/rejoin, verifies SHA-256, matches the source bytes, and reports readiness.
4. `xcodebuild ... -only-testing:GetOverHereUITests/GetOverHereUITests/testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration`
   - Destination: booted simulator `05008420-7A8F-446E-924B-5D698E06F3C6`, parallel testing disabled.
   - Result: pass in 13.465 seconds. The guide creates a tour and reaches Slides, Map, and Pointer without the removed legacy configuration UI. Result bundle: `/tmp/GetOverHereFinalUIDerivedData/Logs/Test/Test-GetOverHere-2026.08.21_18-06-43--0700.xcresult`.
5. iOS packaging audit.
   - Result: signed device build passed. The app bundle contains `PrivacyInfo.xcprivacy`, reports no tracking or collected data, contains `UIBackgroundModes = audio`, and carries the HotspotConfiguration and Wi-Fi Aware development entitlements.
6. Android dependency audit.
   - Result: `debugRuntimeClasspath` resolved successfully and contains MapLibre 13.4.1 but no Google Nearby Connections dependency. `testDebugUnitTest assembleDebug` passed.
7. Current iPhone install and launch.
   - Device: `F043EBB9-780F-5483-B0D1-BC0BD9955D9C`.
   - Result: `devicectl` installed and launched `com.aens.GetOverHere` successfully from `/tmp/GetOverHereFinalDeviceDerivedData/Build/Products/Debug-iphoneos/GetOverHere.app`.
8. Current Android install gate.
   - Result: `adb devices -l` returned no devices. The verified APK is ready at `Android/app/build/outputs/apk/debug/app-debug.apk`; current physical installation is pending reconnection of `66180DLKX006ND`.
9. Remaining field gate.
   - Result: no real `.pmtiles` region archive was supplied, so physical offline-map rendering and two-phone slide/pin/pointer interaction remain pending with the operator's actual map pack and reconnected Android device.

## 2026-08-21 — Final map, bearing-privacy, and readiness verification

Implementation:

- Reduced the shared bearing snapshot to state version, magnetic reference, selected angle, and visibility. Removed compass accuracy and sampling time from both Swift and Kotlin wire contracts.
- Added a verification-script failure if those local compass fields reappear in either shared session core.
- Added explicit unavailable/transferring/ready/failed offline-map states on both platforms so a guest does not wait indefinitely when the guide supplied no map.
- Added Android guide content-readiness state and verified that it decrements on guest disconnect and recovers after rejoin.
- Replaced incomplete PMTiles prefix fixtures with complete one-tile v3 archives and renderer tests.
- Corrected Android local archive URLs from `pmtiles://file:/...` to MapLibre's required `pmtiles://file:///...` form.

Commands and results:

1. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :app:compileDebugKotlin`
   - Result: pass. Only the existing deprecated directional-icon warnings remain.
2. `scripts/verify_tour_session.sh`
   - Result: all seven stages pass after the final wire and map changes: 14 Swift core tests, 14 Kotlin core tests, exact Swift/Kotlin fixture/decode/auth/state equality, 1/8/20/50 churn, realtime fault and privacy audits, 23 Android JVM tests, APK assembly, and 23 iOS Simulator tests.
   - iOS result bundle: `/tmp/GetOverHereTourSessionDerived/Logs/Test/Test-GetOverHere-2026.08.21_19-12-07--0700.xcresult`.
3. Initial physical Android PMTiles repro: `./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.OfflineMapRenderTest`
   - Result: failed first because MapLibre was initialized off the UI thread, then timed out after the harness was corrected. The deterministic timeout isolated the production URL bug.
4. Focused URL test: `./gradlew :app:testDebugUnitTest --tests com.aessam.comeoverhere.OfflineMapPackTest`
   - Result: 4/4 pass, including exact `pmtiles://file:///` spelling, percent-encoded paths, complete-header validation, and out-of-bounds rejection.
5. Corrected physical Android PMTiles repro.
   - Device: Pixel 11 Pro, Android 17, serial `66180DLKX006ND`.
   - Result: pass in 12 seconds. MapLibre rendered a generated complete one-tile PMTiles v3 archive and the test verified the center RGB value.
6. `./gradlew connectedDebugAndroidTest`
   - Result: 4/4 pass on the Pixel: private/speaker physical route switching, 16 kHz voice-communication capture with AEC/noise suppression, app context, and local PMTiles rendering.
7. Final installation.
   - Android: `adb install -r Android/app/build/outputs/apk/debug/app-debug.apk` returned `Success`.
   - iOS: signed physical build succeeded with the configured Apple Development identity; `devicectl` installed `com.aens.GetOverHere` on iPhone `F043EBB9-780F-5483-B0D1-BC0BD9955D9C`.
8. Physical iPhone PMTiles renderer gate.
   - Result: test bundle built and signed; execution is waiting for the locked iPhone to be unlocked.
9. Remaining field gate.
   - Result: two-phone audio plus slide, target, pointer, lock/background, and reconnect interaction still requires the final operator walkthrough. No completion claim is made until it passes.

## 2026-08-21 — Least-privilege and explicit hardware-state closeout

Implementation:

- Android no longer requests microphone, location, or nearby Wi-Fi access at launch. Microphone is guide-only, location is map-only, and nearby Wi-Fi is lab-only.
- Android application backup is disabled so app-owned tour content is not eligible for cloud backup.
- NSD shutdown failures are logged instead of swallowed.
- Both apps distinguish compass acquisition from unavailable/unreliable hardware and clear stale location and heading data when guidance stops.
- Both apps display explicit denied/unavailable location states while keeping the shared target pin visible.

Commands and results:

1. `scripts/verify_tour_session.sh`
   - Result: all seven stages pass after the permission and sensor-state changes: 14 Swift core tests, 14 Kotlin core tests, exact Swift/Kotlin wire/auth/state equality, 1/8/20/50 churn, realtime fault/privacy audits, 23 Android JVM tests plus APK, and 23 iOS Simulator tests.
   - iOS result bundle: `/tmp/GetOverHereTourSessionDerived/Logs/Test/Test-GetOverHere-2026.08.21_19-27-13--0700.xcresult`.
2. `./gradlew connectedDebugAndroidTest`
   - Result: 4/4 pass on Pixel 11 Pro: physical private/speaker routing, 16 kHz guide capture with AEC/noise suppression, app context, and local PMTiles rendering.
3. Final Android build installation and launch.
   - Result: `adb install -r` returned `Success`; `MainActivity` accepted the launch intent.
4. Final iOS signed physical build and installation.
   - Result: build passed and `devicectl` installed `com.aens.GetOverHere` on Dark knight. Remote launch and focused physical PMTiles execution remain blocked while the phone is locked.
5. Remaining acceptance gate.
   - Result: physical two-phone slides, target, pointer, lock/background, reconnect, denied-location, and poor-heading walkthrough remains pending. No completion claim is made.

## 2026-08-21 — Runtime lifetime, compatibility, and final local gate

Implementation:

- Moved the Android tour runtime from `MainActivity` to `ComeOverHereApp`. Configuration-driven Activity recreation no longer ends guide or guest sockets, audio, content, or guidance state.
- Added a physical Android lifecycle test that recreates the Activity and verifies that the same application-owned `ChannelService` survives.
- Restored the production app and Swift session package minimum to iOS 17. The experimental Wi-Fi Aware lab remains runtime-gated to iOS 26.4.
- Added verifier failures for production deployment-target drift, participant metadata or credentials in logs, participant location in shared contracts, and Google Nearby returning to Android production dependencies.
- Preserved guest foreground slide priority: incoming map and pointer focus is queued while a guide-presented slide is visible, then applied after the guide hides the slide.
- Corrected iOS target-map recentering when the guide moves or replaces the pin.
- Replaced stale root documentation with the current authenticated three-lane tour architecture and authoritative product-spec links.

Commands and results:

1. `scripts/verify_tour_session.sh`
   - Result: all seven stages passed: 14 Swift session-core tests, Kotlin core/CLI tests, exact cross-language fixture/decode/auth/state equality, 1/8/20/50 churn, realtime fault and privacy audits, Android JVM tests plus APK assembly, and 23/23 iOS Simulator tests.
   - iOS result bundle: `/tmp/GetOverHereTourSessionDerived/Logs/Test/Test-GetOverHere-2026.08.21_19-53-36--0700.xcresult`.
2. `xcrun xcresulttool get test-results summary --path /tmp/GetOverHereTourSessionDerived/Logs/Test/Test-GetOverHere-2026.08.21_19-53-36--0700.xcresult`
   - Result: `result = Passed`, 23 passed, 0 failed, 0 skipped, 0 expected failures, and no runtime warnings.
3. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew connectedDebugAndroidTest`
   - Device: Pixel 11 Pro, Android 17, serial `66180DLKX006ND`.
   - Result: 6/6 pass, including audio routing, voice capture processing, PMTiles rendering, application context, tour-runtime retention through `ActivityScenario.recreate()`, and the real Compose guide flow through Slides, Map, Pointer, and End Tour.
4. Final Android deployment.
   - `adb install -r Android/app/build/outputs/apk/debug/app-debug.apk` returned `Success`.
   - `adb shell am start -W -n com.aessam.comeoverhere/.MainActivity` returned `Status: ok`.
5. Final iOS deployment.
   - Signed physical build for Dark knight completed successfully at `/tmp/GetOverHereFinalDeviceDerivedData/Build/Products/Debug-iphoneos/GetOverHere.app`.
   - `devicectl` installed bundle `com.aens.GetOverHere` successfully.
   - After Dark knight was unlocked, `devicectl device process launch --terminate-existing com.aens.GetOverHere` succeeded with `Launched application with com.aens.GetOverHere bundle identifier`.
6. Current iOS guide-navigation UI gate.
   - Initial run failed after tour creation because compact `NavigationSplitView` remained on the sidebar even though `activeChannelID` was set. Failure bundle: `/tmp/GetOverHereFinalUIDerivedData/Logs/Test/Test-GetOverHere-2026.08.21_19-48-55--0700.xcresult`.
   - Bound the preferred compact column to active-session state and reran `testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration`.
   - Result: pass. The guide creates a tour and reaches Slides, Map, and Pointer without returning to the list or opening transport configuration. Result bundle: `/tmp/GetOverHereFinalUIDerivedData/Logs/Test/Test-GetOverHere-2026.08.21_19-50-21--0700.xcresult`.
7. Remaining acceptance gate.
   - The focused physical iPhone PMTiles command built the test bundle, then entered Xcode destination preflight when Dark knight relocked. It was cancelled cleanly after the phone remained locked; no test executed and no pass is claimed.
   - Result: physical iPhone PMTiles execution and the two-way iOS/Android audio, slides, target, pointer, lock/background, reconnect, denied-location, and poor-heading walkthrough remain pending with the phone unlocked and awake. No completion claim is made.

## 2026-08-21 — Shared-screen delivery regression and device handoff

Implementation:

- Reproduced the reported behavior: target and bearing snapshots crossed the control socket, but the guest kept a visible slide in the foreground because both UIs inferred slide-first priority.
- Added GOH2 protocol 2.1 `visualFocusSnapshot`: a nine-byte versioned Slides/Map/Pointer selection. The guide sends it on tool changes; late join and reconnect send it after content snapshots.
- Removed the queued guest-tool behavior on iOS and Android. The guide-selected screen now opens immediately while slide, target, and bearing content remain independently recoverable.
- Extended app tests with stale shared-screen rejection, real TCP delivery, and a two-asset transfer containing both a slide and a map archive.
- Extended the Android physical navigation test to prove that tapping Map and Pointer changes the service's authoritative shared-screen state.
- Removed raw names, addresses, device labels, file paths, and exception messages from application logs and added source gates against their return.

Commands and results:

1. `scripts/repro_visual_focus.sh`
   - Before implementation: failed with `error: unknown command: focus`.
   - After implementation: `Shared-screen reproduction passed` with exact Swift/Kotlin result `initial=slides:0|guide=map:1,pointer:2|guest=pointer:2|stale=pointer:2|late=pointer:2`.
2. Focused platform regressions.
   - Android `testDebugUnitTest`: 23/23 pass, including four presentation-service tests, four real local-session transport tests, and verified slide-plus-map archive transfer.
   - iOS `GetOverHereTests`: 23/23 pass. Result bundle: `/tmp/GetOverHereSharedScreenDerived/Logs/Test/Test-GetOverHere-2026.08.21_20-20-25--0700.xcresult`.
3. `scripts/verify_tour_session.sh`
   - Result: all seven stages pass: 16 Swift core tests, 16 Kotlin core tests, exact protocol/auth/state/shared-screen bytes, 1/8/20/50 participant churn, privacy gates, 23 Android JVM tests plus APK, and 23 iOS Simulator tests.
   - iOS result bundle: `/tmp/GetOverHereTourSessionDerived/Logs/Test/Test-GetOverHere-2026.08.21_20-24-41--0700.xcresult`.
4. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew connectedDebugAndroidTest`
   - Device: Pixel 11 Pro, Android 17, serial `66180DLKX006ND`.
   - Result: 6/6 pass. The Compose guide test now asserts that Map and Pointer taps publish the corresponding shared-screen mode.
5. Focused iOS guide UI test.
   - Result: 1/1 pass for creating a tour and navigating Slides, Map, and Pointer. Result bundle: `/tmp/GetOverHereSharedScreenUIDerived/Logs/Test/Test-GetOverHere-2026.08.21_20-27-18--0700.xcresult`.
6. Device deployment.
   - Android: `adb install -r` returned `Success`; launch returned `Status: ok`.
   - iOS: signed device build passed and `devicectl` installed `com.aens.GetOverHere` from `/tmp/GetOverHereSharedScreenDeviceDerived/Build/Products/Debug-iphoneos/GetOverHere.app`.
   - Latest iOS remote launch was denied only because Dark knight locked after installation. The binary is installed; no launch pass is claimed for this build.
7. Remaining acceptance gate.
   - Unlock Dark knight, open the installed app, and run the two-device slide → Map → Pointer sequence plus target movement, lock/background, and reconnect. Collect the operator's pending feedback before any completion claim.

## 2026-08-21 — Requirement audit and missing-map UI gate

Audit result:

- Every production capability in `TourGuideProductSpec.md` has an implementation and automated evidence. No additional production-code omission was found.
- The remaining unproven requirements are physical-runtime gates: iPhone PMTiles rendering, both iOS↔Android guide directions with concurrent audio/assets/state, lock/background, reconnect/restart, denied-location behavior, and degraded-compass behavior.
- Dark knight remained locked during a second launch attempt, so no physical iPhone execution was claimed.

Commands and results:

1. Strengthened Android `TourNavigationTest`.
   - Added direct assertions for `No offline map` and `Import Offline Map`, then retained exact Map and Pointer shared-screen state assertions.
   - Focused physical Pixel run: 1/1 pass.
2. Strengthened iOS `testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration`.
   - Added direct assertions for `No Offline Map` and `Import Offline Map` before entering Pointer.
   - Simulator result: 1/1 pass, 0 failures, 0 skips, and no runtime warnings. Result bundle: `/tmp/GetOverHereMissingMapUIDerived/Logs/Test/Test-GetOverHere-2026.08.21_20-31-41--0700.xcresult`.
3. Android instrumentation cleanup.
   - The focused runner removed its target package after completion. `adb install -r` restored the verified APK and returned `Success`; `MainActivity` launch returned `Status: ok`.
4. Third physical iPhone launch check.
   - `devicectl device process launch --terminate-existing com.aens.GetOverHere` again returned `RequestDenied` with reason `Locked`.
   - This is the third consecutive acceptance turn with the same external device-state blocker. Physical iPhone and two-device acceptance cannot progress until Dark knight is unlocked and kept awake.

## 2026-08-22 — Transport direction and production Aware call-site audit

Investigation:

- Reviewed the current product contract, ADRs, lessons, review, execution handoff, recent commits, and both platform transport ownership.
- Audited the iOS source for production Wi-Fi Aware connection creation and lane construction.
- Reviewed public bitchat iOS and Android sources at commits `9b84b361225facd8e623f25d76f889d3dc54a879` and `09b481f1ef5852ed50edce987dd719bd9588b125` for BLE controlled flooding, fragmentation, deduplication, fan-out, live AAC voice, and Android Wi-Fi Aware behavior. Source-only shallow clones were created under `/tmp` and removed after inspection; no binaries were downloaded, built, or installed.

Commands and results:

1. `rg -n -S "NetworkListener|NetworkBrowser|WiFiAwareAudioPlane|WiFiAwareSessionControlTransport|WiFiAwareSessionAssetTransport" iOS/GetOverHere -g '*.swift'`
   - Result: the only production-target Wi-Fi Aware `NetworkListener` and `NetworkBrowser` call sites are in `WiFiAwareLabTransport.swift`. The three production lane classes exist in `WiFiAwareSessionLaneTransport.swift` but have no application call sites; tests are their only constructors.
2. `rg -n -S "HybridAudioPlane|HybridSessionControlTransport|HybridSessionAssetTransport|HybridSessionRouteController|WiFiAwareAudioPlane\\(|WiFiAwareSessionControlTransport\\(|WiFiAwareSessionAssetTransport\\(" iOS -g '*.swift'`
   - Result: hybrid and Aware lane construction appears only in `HybridSessionTransportsTests.swift`; the normal iOS app remains local-LAN-only.
3. Public source review of bitchat `WHITEPAPER.md`, `VoiceBurstPacket.swift`, `PTTAudioFormat.swift`, `TransportConfig.swift`, and the matching Android voice/mesh sources.
   - Result: both platforms implement the same BLE live-voice packet format using AAC-LC, 16 kHz mono, 16 kb/s, 64 ms access units, TTL routing, deduplication, split horizon, and bounded fan-out. This establishes a concrete implementation reference but provides no GetOverHere physical capacity result.
4. User physical observations considered in the decision.
   - Result: Android-hosted Wi-Fi was unstable on the target device and is removed from the selected production direction. A separate cross-platform AirDrop-like application transferred files successfully, increasing confidence in the device pair's Aware capability; this observation has not been independently reproduced in GetOverHere.

Decision and planning result:

- Added ADR-029: Wi-Fi Aware primary, opportunistic LAN, and bounded BLE control/voice fallback with per-participant route selection.
- Added ADR-030: route-independent application payload encryption.
- Replaced `NextSession.md` with the gate-by-gate execution plan. No product source code changed and no transport completion claim is made.

## 2026-08-22 — Execution-plan risk and sequencing amendment

Review result:

- Moved transport-neutral encoded/encrypted realtime work from after Aware integration to immediately after the baseline checkpoint: P0 → P3 → P1.
- Reclassified the existing LAN path from opportunistic rollback to the guaranteed first-class full-capability floor.
- Added a Wi-Fi Aware stop-loss of four focused physical sessions or two engineering days.
- Recorded the rough 15–25% planning case in which both no-AP audio routes fail and LAN remains required for audio.
- Gave BLE voice the same 2/5/10-device physical emphasis as BLE control and added a mixed AP-less, half-locked/pocketed field case.
- Added ADR-031 for runtime Aware overflow: LAN, then validated BLE voice, then explicit control-only mode.
- Added the P6 guide-radio coexistence/battery gate and ADR-032 accepting session-wide restart as v1 revocation.

No product source code changed and no transport gate is claimed as passed.

Verification:

1. `scripts/verify_tour_session.sh`
   - First sandboxed run: Swift protocol tests passed; Gradle could not create its lock under `~/.gradle` because host cache writes were denied.
   - Host-cache rerun: all seven stages passed, including Swift/Kotlin tests, exact cross-language wire bytes, churn and realtime audits, Android unit/APK integration, and iOS Simulator integration.
   - Final output: `Tour session verification passed`.

## 2026-08-23 — P0 physical-test harness

Implementation:

- Added `scripts/capture_physical_test.sh` with explicit `start`, `mark`, `status`, and `stop` commands.
- The harness validates every selected device before creating a run directory, writes raw output only outside the repository, snapshots public iOS device/process state and Android battery/thermal/connectivity/Wi-Fi/Wi-Fi Aware/Bluetooth/audio state, and backgrounds the iOS app console and Android logcat.
- The harness never clears logs, terminates an existing app, collects sysdiagnose, or inspects private frameworks or binaries.
- Added `.claude/` and `/Review-22Aug26.md` to `.gitignore` so the tracked-tree signal remains clean without deleting either local input.

Commands and results:

1. `bash -n scripts/capture_physical_test.sh`
   - Result: passed.
2. `scripts/capture_physical_test.sh start`
   - Result: rejected the missing device selection before creating output.
3. `scripts/capture_physical_test.sh status --run-dir /Users/aessam/tmp/ios-macos-apps/GetOverHere/PhysicalRuns/test`
   - Result: rejected a raw-log directory inside the repository.
4. `scripts/capture_physical_test.sh start --android-serial definitely-missing --run-dir /tmp/GetOverHerePhysicalRuns/missing-android-2`
   - Result: rejected the missing Android device and left no partial directory.
5. `scripts/capture_physical_test.sh start --ios-device 00008150-001208901AC0401C --run-dir /tmp/GetOverHerePhysicalRuns/p0-ios-smoke-20260823`
   - Result: correctly failed before capture because the physical iPhone was locked and its developer disk image could not be mounted. No partial directory was created. Android was not attached, so no Android physical capture is claimed.
6. `scripts/verify_tour_session.sh`
   - Result: all seven stages passed. Final output: `Tour session verification passed`.

P0 provides the reusable capture path and preserves the passing baseline. The first complete two-device artifact will be captured when both devices are connected and unlocked during P3; no radio or physical-audio gate is claimed here.

## 2026-08-23 — P3 pre-fixture contract and native-codec research

Decisions locked before wire fixtures:

- Encrypt once at logical-frame creation and route the immutable sealed bytes. Transport/socket writers do not encrypt or allocate nonces.
- Derive the nonce from the key and immutable route-independent identity. A second plaintext for an already-used identity is rejected before encryption.
- Increment the GOH2 protocol major for encrypted frames and map legacy-major decode to an explicit product version-mismatch state. Plaintext downgrade is forbidden.
- Probe installed native codecs before selecting a realtime codec or adding a dependency.

Primary-source findings:

- Apple documents `kAudioFormatOpus` and `kAudioFormatProperty_EncodeFormatIDs`/`kAudioFormatProperty_Encoders`; the physical device still must prove an installed encoder and a real encode/decode roundtrip.
- Android documents `MediaCodecList.findEncoderForFormat` and codec enumeration through `codecInfos`/`isEncoder`/`supportedTypes`.
- Android's supported-media table guarantees Opus encoding on handhelds/tablets from Android 10 and Opus decoding from Android 5. The app's Android 8 minimum still requires runtime negotiation; the target Pixel must be probed directly.
- No `libopus` dependency is authorized during the native-codec spike.

Sources:

- https://developer.apple.com/documentation/coreaudiotypes/kaudioformatopus
- https://developer.apple.com/documentation/audiotoolbox/kaudioformatproperty_encodeformatids
- https://developer.apple.com/documentation/audiotoolbox/kaudioformatproperty_encoders
- https://developer.android.com/media/platform/supported-formats
- https://developer.android.com/reference/android/media/MediaCodecList
- https://developer.android.com/reference/android/media/MediaCodecInfo

## 2026-08-23 — P3 native-codec capability probe

Implementation:

- Added an iOS `AudioFormatGetProperty` probe for installed Opus and AAC-LC encoders/decoders.
- Added an Android `MediaCodecList.findEncoderForFormat`/`findDecoderForFormat` probe for the intended 16 kHz mono Opus and AAC-LC formats.
- Added focused Swift Testing and Android instrumentation tests. No codec dependency, GOH2 wire change, or codec selection was made.

Commands and results:

1. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/GetOverHereCodecProbeDerived test -only-testing:GetOverHereTests/NativeAudioCodecCapabilitiesTests`
   - Result: passed on the iPhone 17 Pro simulator.
2. `env JAVA_HOME=/Applications/Android\\ Studio.app/Contents/jbr/Contents/Home ./gradlew :app:compileDebugKotlin :app:compileDebugAndroidTestKotlin assembleDebugAndroidTest`
   - Result: passed; the app and instrumentation probe compiled and the test APK assembled.
3. `/Users/aessam/Library/Android/sdk/platform-tools/adb devices -l`
   - Result: no Android device was attached, so no Android codec capability result is claimed.
4. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'id=00008150-001208901AC0401C' -derivedDataPath /tmp/GetOverHerePhysicalCodecProbeDerived test -only-testing:GetOverHereTests/NativeAudioCodecCapabilitiesTests`
   - Result: failed before test execution because `Dark knight` was locked and development services could not start. No physical iOS codec capability result is claimed.

P3 remains stopped before the codec-dependent wire fixture until both physical probes run.

## 2026-08-26 — P3 encrypted-frame and encoded-audio contract checkpoint

Scope adjustment:

- Hardware is unavailable. Physical codec, RF, latency, background, thermal, and battery gates remain pending by explicit user direction.
- P3 implementation proceeds with deterministic shared-core tests, iOS Simulator, and Android emulator/device-test infrastructure. No physical result is inferred from those environments.

Implementation:

- Added a version-3 encrypted session envelope while retaining `GOH2` magic so legacy major `2` can be rejected as an explicit version mismatch.
- Added route-independent frame identity using session, sender, stream, lane, kind, flags, and sequence.
- Added encrypt-once AES-256-GCM sealing with a nonce derived from the tour key and immutable frame identity. Re-sealing identical plaintext returns byte-identical ciphertext; different plaintext under a used identity is rejected.
- Added authenticated header fields, tamper rejection, wrong-tour-key rejection, and duplicate detection.
- Added cross-platform Opus/AAC-LC capability bits, codec selection, and an encoded-audio payload with codec configuration, capture time, expiry, and encoded bytes.
- Added deterministic Swift/Kotlin CLI fixtures and extended `scripts/verify_tour_session.sh` to compare encrypted frame bytes, encoded-audio bytes, and cross-language encrypted decode results.

Commands and results:

1. `swift test --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereP3CoreSwift`
   - Result: passed, including encryption identity, tamper, replay, version mismatch, audio payload, and codec negotiation tests.
2. `env JAVA_HOME=/Applications/Android\\ Studio.app/Contents/jbr/Contents/Home ./gradlew :tour-session-core:test :tour-session-cli:installDist`
   - Result: passed with the matching Kotlin contract tests.
3. Swift/Kotlin `encrypted-fixture` and `audio-fixture` CLI outputs
   - Result: exact byte equality for AES-GCM encrypted session frames and encoded-audio payloads.
4. `scripts/verify_tour_session.sh`
   - Result: all seven stages passed, including both cores, cross-language fixtures, Android app/APK integration, and the iOS Simulator test suite.

This checkpoint defines and proves the new contract. Existing application transports still use the legacy plaintext envelope until the next focused integration checkpoint; no production encryption claim is made yet.

## 2026-08-26 — P3 native codec and bounded-buffer checkpoint

Implementation:

- Added platform-native Opus and AAC-LC encoders/decoders behind matching realtime codec interfaces.
- Standardized codec input/output on 16 kHz mono PCM16 little-endian frames.
- Added codec-specific configuration bytes to the exact Swift/Kotlin encoded-audio wire contract.
- Added an exact-frame PCM accumulator and a bounded, expiry-aware encoded-frame jitter buffer in both session cores.
- Added native capability and encode/decode roundtrip tests on both platforms. No `libopus` or other codec dependency was added.

Commands and results:

1. `swift test --package-path Packages/TourSessionCore`
   - Initial focused buffer test trapped in `Data.subdata(in:)` after `removeFirst` advanced the collection start index. The accumulator now uses `prefix` plus removal.
   - Focused regression rerun passed.
2. `env JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home ./gradlew :tour-session-core:test :app:compileDebugKotlin :app:compileDebugAndroidTestKotlin`
   - Result: passed after correcting the Kotlin test's `Int`/`Long` assertion type.
3. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/GetOverHereP3NativeCodec test -only-testing:GetOverHereTests/NativeRealtimeAudioCodecTests -only-testing:GetOverHereTests/NativeAudioCodecCapabilitiesTests`
   - Result: four tests passed. Native Opus and AAC-LC each produced compressed packets and decoded PCM on the iPhone 17 Pro simulator.
4. Installed Google's official Android command-line tools `15859902`, verified SHA-256 `835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e`, installed `system-images;android-36;default;arm64-v8a`, and created `GetOverHere_API_36`.
   - The Google APIs image requested a separate unaccepted license and was not installed. No license was accepted on the user's behalf.
5. `env JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home ./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.NativeRealtimeAudioCodecTest`
   - Result: two tests passed on `GetOverHere_API_36`, Android 16, ARM64. Native Opus and AAC-LC capability mapping and encode/decode roundtrips passed.
6. `scripts/verify_tour_session.sh`
   - Result: all seven stages passed, including 24 Swift core tests, the matching Kotlin core suite, exact cross-language frame checks, Android app/APK integration, and the full iOS Simulator suite. Final output: `Tour session verification passed`.

Simulator and emulator results validate code paths, wire configuration, compression, and bounded buffering. They do not satisfy the physical codec, audio quality, mouth-to-ear latency, RF, background, thermal, or battery parts of Gate P3.

## 2026-08-26 — P3 encrypted LAN control and asset checkpoint

Implementation:

- Migrated LAN control and asset handshakes and application frames from plaintext GOH2 v2 envelopes to immutable AES-GCM-sealed GOH2 v3 frames.
- Reset stream identities and replay windows for each transport start/reconnect and ignored authenticated duplicate frames.
- Added typed version-mismatch events through transport and service layers. A new build receiving a legacy v2 frame reports `remote 2, local 3` and does not downgrade or reconnect-loop.
- Added Swift and Kotlin socket tests for encrypted bidirectional control, targeted asset transfer, wrong credentials, and explicit legacy-major rejection.

Commands and results:

1. `env JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home ./gradlew :app:testDebugUnitTest --tests com.aessam.comeoverhere.LocalSessionTransportTest --tests com.aessam.comeoverhere.TourAssetTransferServiceTest`
   - Result: passed, 6 focused transport/asset tests.
2. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/GetOverHereP3EncryptedLocal2 test -only-testing:GetOverHereTests/LocalSessionTransportTests -only-testing:GetOverHereTests/TourAssetTransferServiceTests`
   - Result: passed, 6 focused transport/asset tests on the iPhone 17 Pro simulator.
3. The first combined iOS run timed out in the asset readiness test while the simulator was starting under concurrent load. The unchanged asset suite then passed in isolation in 0.134 seconds and passed again in the final combined run in 0.042 seconds.

Realtime audio and Wi-Fi Aware lane integration remain outside this checkpoint. No claim is made that every application payload path is encrypted yet.

## 2026-08-26 — P3 canonical PCM16 application boundary

Implementation:

- Changed iOS capture conversion and playback buffers from non-interleaved Float32 to interleaved 16 kHz mono PCM16.
- Removed Android's PCM16→Float32→PCM16 conversion and configured `AudioTrack` for PCM16 directly.
- The transport still carries uncompressed PCM at this checkpoint; encoding and sealing are the next checkpoint.

Commands and results:

1. `env JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home ./gradlew :app:compileDebugKotlin :app:testDebugUnitTest`
   - Result: passed.
2. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/GetOverHereP3PCM16 build`
   - Result: passed.

## 2026-08-27 — P3 encrypted encoded LAN integration checkpoint

Implementation:

- Integrated native Opus/AAC-LC negotiation, exact PCM16 frame accumulation, encoded GOH2 audio payloads, encrypt-once sealing, duplicate rejection, and bounded jitter into both LAN audio transports.
- Reused one sealed frame for every LAN listener that negotiated the same codec. Codec-specific streams have independent identities and sequences.
- Added explicit audio-lane legacy-version rejection and propagated typed failure state to both product services.
- Moved native codec implementations beside the transport boundary and added injectable codec providers for deterministic socket tests.
- Sealed iOS Wi-Fi Aware control and asset lanes. Disabled raw Wi-Fi Aware and Multipeer audio until a route-neutral sealed-frame producer owns concurrent route delivery.
- Added `scripts/verify_no_plaintext_session_paths.sh` and made it stage 6 of the full verifier.
- Replaced cross-device wall-clock expiry comparison with monotonic sender/receiver timelines and minimum-observed-offset compensation.

Commands and results:

1. `swift test --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereP3ClockSwift`
   - Result: 24 tests passed, including deliberate sender/receiver clock skew, excess-delay expiry, encrypted identity, replay, and bounded jitter.
2. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :tour-session-core:test :app:testDebugUnitTest --tests com.aessam.comeoverhere.LocalSessionTransportTest`
   - Result: passed, including the matching Kotlin clock-skew contract and encrypted encoded LAN loopback.
3. `adb -s emulator-5554 shell am instrument -w -e class com.aessam.comeoverhere.NativeRealtimeAudioCodecTest com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner`
   - Result: `OK (3 tests)` on the Android 16 ARM64 emulator. Native Opus, AAC-LC, and encrypted native-codec LAN transport passed. The attached physical Pixel was not targeted.
4. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereP3FinalIOS test -only-testing:GetOverHereTests`
   - Result: passed after replacing cross-task mutable callbacks with a lock-protected callback store.
5. `scripts/verify_no_plaintext_session_paths.sh`
   - Result: passed. No plaintext GOH2 decode/write path or raw Float32 audio path was found in the enumerated production transports.
6. `scripts/verify_tour_session.sh`
   - Result: all eight current-tree stages passed, including exact Swift/Kotlin encrypted bytes, clock-skew/expiry behavior, Android encrypted LAN loopback and APK, the plaintext-path audit, and the full iOS Simulator suite. Final output: `Tour session verification passed`.

This completes the non-hardware P3 implementation on the LAN floor. Gate P3 remains open until its physical codec, 30-minute audio, loss, mouth-to-ear latency, background, thermal, and battery measurements pass.

## 2026-08-28 — Idle iOS session timeout repair

Implementation:

- Cleared the iOS control/asset guest socket receive timeout after authenticated handshake completion.
- Added a simulator regression that leaves the guide idle for six seconds, then verifies the guest still receives an encrypted control heartbeat.

Commands and results:

1. `scripts/verify_tour_session.sh`
   - Baseline result before edits: all eight stages passed at `9793607`. The first sandboxed run could not acquire the existing Gradle wrapper lock; the unchanged verifier passed when granted access to the existing Gradle and Xcode caches.
2. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereH1 test -only-testing:GetOverHereTests/LocalSessionTransportTests/controlLaneSurvivesIdleGuide`
   - Result: passed on the iPhone 17 Pro simulator after the six-second idle interval.
3. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereH1 test -only-testing:GetOverHereTests/LocalSessionTransportTests`
   - Result: the complete iOS local-session transport suite passed.

## 2026-08-28 — Android API-floor and production Aware re-gate

Implementation:

- Removed `WiFiAwareSessionTransport` from the production Android object graph and removed the launch-time nearby-Wi-Fi permission request. The Android-14 lab remains available only through its explicit UI entry.
- Added a verifier source audit that fails if production coordinator/service/view-model/screen call sites reintroduce Aware before P1 passes.
- Replaced both API-33 `InputStream.readNBytes` calls with one bounded API-26 helper and added a two-stage bounded-read regression.
- Added explicit microphone and nearby-Wi-Fi permission preflights, isolated Aware implementations behind Android-14 API boundaries, and handled discovery permission failures.
- Added `lintDebug` as stage 7 of the now nine-stage session verifier.

Commands and results:

1. `./gradlew lintDebug testDebugUnitTest assembleDebug`
   - Result: failed before Gradle started because the non-login shell had no Java runtime configured. No project stage ran.
2. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew lintDebug testDebugUnitTest assembleDebug`
   - Result: passed. Android lint reported no errors; JVM tests and the debug APK build passed.
3. `scripts/verify_tour_session.sh`
   - Result: all nine stages passed, including Android lint, the production Aware call-site audit, cross-platform wire fixtures, Android integration/APK, and the iOS simulator suite. Final output: `Tour session verification passed`.

## 2026-08-28 — Discovery and authenticated-session authority repair

Implementation:

- Replaced Bonjour/NSD-originated terminal events with non-terminal `channelUnavailable` events on both platforms.
- Preserved the active session credential and reconnect state during discovery loss while still removing inactive browse-list entries.
- Added authenticated encrypted `leave` handling to the reliable control lane and flushed terminal leave delivery before guide transport shutdown.
- Added source audits and Swift/Kotlin regressions for discovery round trips, authenticated end handling, and terminal delivery before immediate shutdown.

Commands and results:

1. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest --tests com.aessam.comeoverhere.PresentationServiceTest --tests com.aessam.comeoverhere.LocalSessionTransportTest lintDebug`
   - Initial result: test compilation failed because one new fixture used positional arguments against the named `SessionEnvelope` constructor contract. The fixture was corrected to named fields.
   - Final result: passed. Both focused JVM suites and Android lint completed without errors.
2. `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereH5 test -only-testing:GetOverHereTests/PresentationServiceTests -only-testing:GetOverHereTests/LocalSessionTransportTests`
   - Result: passed on the iPhone 17 Pro simulator.
3. `scripts/verify_tour_session.sh`
   - Result: all nine stages passed, including the discovery-authority audit, exact Swift/Kotlin encrypted fixtures, Android loopback/APK/lint, and the complete iOS simulator suite. Final output: `Tour session verification passed`.

## 2026-08-28 — Authenticated minor-version and replay-window repair

Implementation:

- Preserved the encrypted envelope's received minor version and used that value to reconstruct AEAD additional authenticated data.
- Added an explicit configurable sealer minor for compatible-version fixtures while retaining protocol minor zero as the production default.
- Replaced the global digest FIFO with a bounded per-session/sender/stream sequence window that retains a monotonic replay floor.
- Added equivalent Swift/Kotlin tests for minor-version roundtrip, minor tampering, reordered acceptance, duplicate detection, and replay after eviction.

Commands and results:

1. `swift test -q`
   - Result: 26 Swift core tests passed.
2. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :tour-session-core:test`
   - Result: Android core tests passed. The first sandboxed invocation could not acquire the existing Gradle cache lock; the unchanged command passed with access to that cache.
3. `scripts/verify_tour_session.sh`
   - Result: all nine stages passed. Exact Swift/Kotlin encrypted fixture bytes remained unchanged, Android lint/integration/APK passed, and the full iOS simulator suite passed. Final output: `Tour session verification passed`.

## 2026-08-28 — Socket concurrency and fan-out isolation repair

Implementation:

- Moved production iOS LAN accept/connect/read loops from `Task { @concurrent }` to dedicated dispatch queues.
- Added managed descriptor lifetime and per-peer bounded writers with generation checks and send deadlines on iOS; added matching per-peer bounded/deadline writers on Android.
- Removed shared fan-out send queues on both platforms and moved iOS realtime encode/seal off MainActor to one serial processor.
- Added a 24-guest iOS control-lane regression, stalled-peer isolation tests on Swift/Kotlin, and a verifier source audit preventing cooperative blocking I/O or shared send queues from returning.

Commands and results:

1. Focused iOS transport and socket-writer tests.
   - Initial result: the new socket test did not compile because two required Testing assertions omitted `try`; corrected immediately.
   - Final result: the 24-guest authentication test, stalled-writer isolation test, existing idle-session test, and terminal-leave test passed on the iPhone 17 Pro simulator.
2. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest --tests com.aessam.comeoverhere.BoundedSocketFrameWriterTest --tests com.aessam.comeoverhere.LocalSessionTransportTest lintDebug`
   - Result: passed. The stalled Android writer timed out without delaying the healthy writer; transport tests and lint passed.
3. `scripts/verify_tour_session.sh`
   - First result: failed at Android integration because the guest received authenticated `leave`, then reported the guide's expected close as a connection failure. Both guests now terminate their read loop immediately after authenticated leave.
   - Final result: all nine stages passed, including exact encrypted fixtures, source security/concurrency audits, Android lint/loopback/APK, the 24-guest iOS regression, stalled-peer tests, and the complete iOS simulator suite. Final output: `Tour session verification passed`.

## 2026-08-28 — Capture failure and terminal credential-lifetime repair

Implementation:

- Made iOS capture setup throwing and transactional. Audio-session configuration, converter creation, and engine startup now fail the guide session instead of publishing invalid bytes or a silent LIVE state.
- Removed the hardware-buffer-as-PCM16 fallback and added a verifier source gate plus simulator regression.
- Added explicit `clearSession()` lifecycle operations to Swift and Kotlin audio, control, and asset transports. Terminal paths erase credentials; reconnect retains its admitted credential in `ChannelService` and uses non-terminal `stop()`.
- Added Swift and Kotlin regressions proving a cleared local transport cannot restart without fresh configuration.

Commands and results:

1. `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest lintDebug`
   - Result: passed. Android unit tests and lint completed with no errors.
2. `scripts/verify_tour_session.sh`
   - Result: all nine stages passed: 26 Swift core tests, Kotlin core tests, byte-exact cross-language encrypted fixtures, security/source audits, Android API-floor lint, Android loopback/APK, and the complete iOS simulator suite including explicit simulator capture failure and credential erasure. Final output: `Tour session verification passed`.

## 2026-09-02 — G1 cores: typed version error, guest mismatch text, canonical asset order, cross-decoded fixtures

Environment (run on 2026-09-03): Apple M4 Max, Xcode 27.0 (27A5218g) at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` (`DEVELOPER_DIR`), Apple Swift 6.4 (swiftlang-6.4.0.25.4), `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` (openjdk 21.0.8), simulator `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG1/ios`, gate derived data `/tmp/GetOverHereFixG1/verifier-ios`, Swift scratch `/tmp/GetOverHereFixG1/swift` (focused) and `/tmp/GetOverHereFixG1/verifier-swift` (gate). No physical device; no emulator needed for this group.

Implementation:

- `SessionProtocolError.unsupportedMajorVersion(received:supported:)` on both Swift decode paths; Kotlin plaintext decode throws `UnsupportedSessionVersionException`; the nine iOS catch sites bind both majors from the decoder; `ChannelService.versionMismatchMessage` on both platforms; guest status presenters (`guestStatusText` / `guestConnectionStatusText`) render the recorded reason on FAILED, red and wrapping on iOS.
- Tour-pack and slide manifests order by `(order, UTF-8 bytes)` and dedup on exact bytes on both cores (ADR-041, DSCN-7); new `SessionProtocolError.duplicateSlideID`.
- Generalized CLI describers (`decode HEX[|HEX...]`, `decode-encrypted`, `decode-audio`), new `handshake` and `realtime-fixture` commands, `state` fixture extended with two tie-breaking slides, two tie-breaking tour-pack assets, and an `assetChunk` envelope; verifier stages 3/4 rewritten with variable-assigned, non-empty-guarded compares, cross-decodes for state/handshake/realtime/audio, and the per-element UTF-8 ordering invariant.

Commands and results:

1. Baseline before edits: `swift test --disable-sandbox --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereFixG1/swift`
   - Result: 26 tests in 2 suites passed.
2. Baseline before edits: `cd Android && JAVA_HOME=... ./gradlew :tour-session-core:test :tour-session-cli:installDist`
   - Result: BUILD SUCCESSFUL (8 tasks up-to-date).
3. Fail-before on unchanged sources: `swift test ... --filter 'tourPackOrderingIsUTF8ByteOrderWithExactDedup|slideManifestOrderingIsUTF8ByteOrderWithExactDedup'`
   - Result: 2 tests failed with 5 issues. Tour pack: `Caught error: duplicate tour asset ID café` (NFC/NFD collapsed by `Set<String>`). Slide manifest: order `[astral, fullwidth, gate-left]`, `[[195,169],[122]]`, `[[97,98],[97]]` (no tie-break).
4. Fail-before on unchanged sources: `./gradlew :tour-session-core:test --tests '...plaintextProtocolRejectsLegacyMajorExplicitly' --tests '...tourPackOrderingIsUtf8ByteOrderWithExactDedup' --tests '...slideManifestOrderingIsUtf8ByteOrderWithExactDedup'`
   - Result: 3 tests completed, 3 failed (AssertionError at :147 caused by base `SessionProtocolException`; :177 astral sorted before fullwidth; :237 slide order).
5. Fail-before for the two-value error shape: `swift build --build-tests ...` with `plaintextVersionMismatchCarriesBothMajors` added
   - Result: `SessionProtocolTests.swift:164:40: error: extra argument 'supported' in call` and `:169:101`.
6. After FND-10 edits: `swift test ...` → 29 tests, only the two FND-11 tie-break tests failing; `./gradlew :tour-session-core:test :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.GuestConnectionStatusTest' --continue` → core 29 tests, 2 failed (same two), `GuestConnectionStatusTest` 4/4; `DEVELOPER_DIR=... xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG1/ios test -only-testing:GetOverHereTests/GuestConnectionStatusTests -only-testing:GetOverHereTests/LocalSessionTransportTests` → exit 0.
7. Golden generation after FND-11 edits: `swift build ... --product tour-session-swift`, `./gradlew :tour-session-cli:installDist`, then `diff <(swift-cli $c) <(kotlin-cli $c)` for `fixture encrypted-fixture audio-fixture state handshake realtime-fixture auth`
   - Result: all seven identical. Cross-decodes (`decode`, `decode-encrypted`, `decode-audio`) of the other side's bytes identical in both directions for state (9 lines), handshake (3 lines), sealed realtime, and audio. Under bash, `state` elements 5 (assetManifest) and 6 (tourPackManifest) each contain `efbd9e` before `f09f97ba`. The 2-asset tie manifest hex was taken from the Swift and Kotlin test failure output against a `PENDING` placeholder and diffed: identical. Only identical strings were pasted into both test files.
8. `swift test ...` → 32 tests in 2 suites passed. `./gradlew :tour-session-core:test` → BUILD SUCCESSFUL, `SessionProtocolTest` 20/20, `ParticipantRegistryTest` 12/12.
9. `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG1/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG1/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG1/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG1/verifier-ios-modules scripts/verify_tour_session.sh`
   - Result: all nine stages passed. Stage 1: 32 Swift tests. Stage 2: Kotlin core tests and CLI install. Stages 3/4: exact bytes and cross-decodes for hello, encrypted hello, audio, handshake, realtime, state, auth, plus the per-element ordering invariant. Stage 8: `:app:testDebugUnitTest` 13 classes, 35 tests, 0 failures, `assembleDebug` built. Stage 9: `Test-GetOverHere-2026.09.03_16-26-16--0700.xcresult` totalTestCount 43, passedTests 43, failedTests 0. Final output: `Tour session verification passed`.

## 2026-09-02 — G2 credential: PBKDF2 stretch and sealed major 4

Environment (run on 2026-09-03): Apple M4 Max, macOS 27.0, Xcode 27.0 (27A5218g) at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` (`DEVELOPER_DIR`), Apple Swift 6.4 (swiftlang-6.4.0.25.4), `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` (openjdk 21.0.8), simulator `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG2/ios`, gate derived data `/tmp/GetOverHereFixG2/verifier-ios`, Swift scratch `/tmp/GetOverHereTourSessionSwift` (focused) and `/tmp/GetOverHereFixG2/verifier-swift` (gate). Android emulator `GetOverHere_API_36` (AVD, `emulator-5554`, Android 16, API 36, arm64-v8a, "Android SDK built for arm64"), already booted. No physical device.

Implementation:

- `SessionCredential.derive` on both cores now runs PBKDF2-HMAC-SHA256 (600,000 iterations, 32 bytes, salt = sessionID wire bytes || `GetOverHere/GOH4/credential-salt/v1`) over the normalized ASCII code before the unchanged HMAC expansion; CommonCrypto `CCKeyDerivationPBKDF` on Apple with `SessionSecurityError.keyStretchFailed(status)`, `javax.crypto` `PBKDF2WithHmacSHA256` on the JVM/Android. Iteration count, salt label, and output size are public wire-contract constants (ADR-042).
- `SealedSessionEnvelope.majorVersion` / `MAJOR_VERSION` 3 → 4; majors 2 and 3 are rejected as `unsupportedMajorVersion(received:supported:)` / `UnsupportedSessionVersionException`.
- Goldens regenerated on both sides: encrypted hello fixture, auth fixture, and G1's sealed realtime fixture; known-answer test `credentialStretchContract` / `credentialStretchIsAPbkdf2WireContract` pins the constants, the raw PBKDF2 output, and the final key; `authenticationProofs` now also asserts `derive("23456-789 ab").key == fixtureCredential().key` (normalization before stretch).
- Both `ChannelService`s derive off the main thread (iOS `@concurrent` static `stretchCredential`, Android `withContext(Dispatchers.Default)`) inside new `startGuideSession` / `startGuestSession` helpers, guarded by the monotonic `sessionAttempt` (DSCN-20). The iOS `audioHostIP` guard and the Android `participantID` guard run before the hop.
- App-level measurements: `TourSessionCoreIntegrationTests.stretchedCredentialBudget` (simulator) and instrumented `SessionCredentialStretchTest` (emulator), both with the DSCN-8 5 s sanity ceiling only.

Vectors: computed independently before either core changed by `scratchpad/g2_vectors.py` (Python `hashlib.pbkdf2_hmac` + `cryptography` AES-GCM), which first reproduced the major-3 encrypted hello and auth goldens byte-for-byte and then produced the major-4 values pasted into both test files. Fixture salt `00112233445566778899aabbccddeeff4765744f766572486572652f474f48342f63726564656e7469616c2d73616c742f7631`, raw PBKDF2 `92ed1ff17b00d8ed95c29c42930eea012bf535f0375174f8c01b0caa46bef215`, credential key `21ad5672cb5998d6c28ca6573e170ca605c0d71d22ae25ede7444c124ef4b1cf`.

Commands and results:

1. Fail-before (compile form): `git stash push -- <the four core source files>`, then `DEVELOPER_DIR=... swift build --build-tests --disable-sandbox --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereFixG2/failbefore-swift` and `cd Android && JAVA_HOME=... ./gradlew :tour-session-core:compileTestKotlin -q`, then `git stash pop`
   - Result: Swift `SessionProtocolTests.swift:531-535: error: type 'SessionCredential' has no member 'stretchIterations' / 'stretchSaltLabel' / 'stretchedKeySize' / 'stretch'`; Kotlin `SessionProtocolTest.kt:547-553: Unresolved reference 'STRETCH_ITERATIONS' / 'STRETCH_SALT_LABEL' / 'STRETCHED_KEY_SIZE' / 'stretch'`. The regenerated goldens and the `[2, 3]` legacy loop live in the same files, so they cannot run against the old cores; the Python model above is the independent proof that the old goldens were the single-HMAC values and the new ones are the PBKDF2 values.
2. `DEVELOPER_DIR=... swift test --disable-sandbox --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereTourSessionSwift --filter SessionProtocolTests`
   - Result: 33 tests in 2 suites passed (`Encrypted protocol rejects legacy majors explicitly` with 2 test cases, `Credential stretch is a PBKDF2 wire contract`, `Authentication proofs are stable and reject another tour code` 0.562 s). Wall 8.4 s including build.
3. `cd Android && JAVA_HOME=... ./gradlew :tour-session-core:test --tests 'com.aessam.toursession.SessionProtocolTest'`
   - Result: BUILD SUCCESSFUL, `SessionProtocolTest` 21 tests, 0 failures.
4. `swift build ... --product tour-session-swift`, `./gradlew :tour-session-cli:installDist`, then `diff` of Swift vs Kotlin output for `fixture encrypted-fixture audio-fixture handshake realtime-fixture state auth`
   - Result: all seven identical (236, 300, 84, 458, 256, 2598, 129 hex chars). `realtime-fixture`, `encrypted-fixture`, and `auth` equal the literals in both test files. Cross `decode-encrypted` of the other side's `encrypted-fixture` and `realtime-fixture` identical in both directions and print `version=4.0|...`.
5. `cd Android && JAVA_HOME=... ./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.TourSessionCoreIntegrationTest' --tests 'com.aessam.comeoverhere.LocalSessionTransportTest' --tests 'com.aessam.comeoverhere.PresentationServiceTest' --tests 'com.aessam.comeoverhere.TourAssetTransferServiceTest'`
   - Result: BUILD SUCCESSFUL; 1 + 8 + 6 + 1 tests, 0 failures.
6. `DEVELOPER_DIR=... xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/GetOverHereFixG2/ios -parallel-testing-enabled NO test -only-testing:GetOverHereTests/TourSessionCoreIntegrationTests -only-testing:GetOverHereTests/LocalSessionTransportTests -only-testing:GetOverHereTests/PresentationServiceTests -only-testing:GetOverHereTests/TourAssetTransferServiceTests`
   - Result: `** TEST SUCCEEDED **`, 20 tests in 4 suites passed; `grep 'PBKDF2 derive'` → `PBKDF2 derive (simulator): 0.150139667 seconds`. Wall 52 s.
7. `adb logcat -c; cd Android && JAVA_HOME=... ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.SessionCredentialStretchTest; adb logcat -d -s SessionCredentialStretchTest`
   - Result: `Finished 1 tests on GetOverHere_API_36(AVD) - 16`, BUILD SUCCESSFUL, testcase time 1.533 s; logcat `PBKDF2 derive (emulator): 1545 ms`. Under the DSCN-8 3 s threshold, so 600,000 iterations hold; the auth-hex assertion proves the device BouncyCastle provider equals SunJCE and CommonCrypto.
8. Wall-time delta (critique minor): `git stash push -u`, `swift test --skip-build ...` and `./gradlew :tour-session-core:cleanTest :tour-session-core:test -q` on the pre-G2 tree, `git stash pop`, same commands after
   - Result: Swift core suite 32 tests in 0.006 s (1.03 s wall) → 33 tests in 0.582 s (1.58 s wall); Kotlin core 1.32 s wall → 2.75 s wall. About one stretch per `derive` call site.
9. `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG2/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG2/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG2/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG2/verifier-ios-modules scripts/verify_tour_session.sh`
   - Result: all nine stages passed in 1:49 wall. Stage 1: 33 Swift tests. Stage 2: Kotlin core tests and CLI install. Stages 3/4: exact bytes and cross-decodes for hello, encrypted hello (`version=4.0`), audio, handshake, sealed realtime, state, auth, plus the per-element ordering invariant. Stage 8: `:app:testDebugUnitTest` 13 classes, 35 tests, 0 failures, `assembleDebug` built. Stage 9: `Test-GetOverHere-2026.09.03_20-07-15--0700.xcresult` totalTestCount 44, passedTests 44, failedTests 0. The log also carries one xcodebuild line `error: the following command failed with exit code 0 but produced no further output` for the warning-only compile of `TourAssetCacheTests.swift` (main-actor initializer warnings at :27, :52); that warning is present in G1's verifier log too, the file is untouched by G2, and xcodebuild exited 0. Final output: `Tour session verification passed`.

## 2026-09-02 — G3 realtime: audio-lane reconnect, off-main Android encode, TCP_NODELAY, clocked playout

Environment (run on 2026-09-03): Apple M4 Max, macOS 27.0, Xcode 27.0 (27A5218g) at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` (`DEVELOPER_DIR`), Apple Swift 6.4 (swiftlang-6.4.0.25.4), `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` (openjdk 21.0.8), simulator `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG3/ios`, gate derived data `/tmp/GetOverHereFixG3/verifier-ios`, Swift scratch `/tmp/GetOverHereFixG3/swift` (focused) and `/tmp/GetOverHereFixG3/verifier-swift` (gate). Android emulator `GetOverHere_API_36` (AVD, `emulator-5554`, Android 16, API 36, arm64-v8a), already booted. No physical device.

Implementation:

- Both cores: `EncodedAudioJitterBuffer.popForPlayout(nowNanoseconds:)` returning `EncodedAudioPlayoutDecision` (`frame` / `conceal(missingSequence)` / `wait`) replaces `popReady`; `TourSessionFixtures.simulatePlayout()` and the `playout` CLI subcommand pin `w,w,f1,f2,w,c3,f4,f10,f11,w`; no wire bytes changed (ADR-045).
- `UDPAudioPlane.swift` / `UDPAudioPlane.kt`: `TCP_NODELAY` / `tcpNoDelay = true` on accepted and connecting sockets (ADR-043); internal `PlayoutClock` (`audio.tcp.playout` queue / `goh2-audio-playout` thread, injectable clock, manual `tick()`, one 640-byte silence frame per concealed sequence, decoder confined to the playout thread, decode failure reported once); Android `BroadcastProcessor` on `audio-encode-seal` and `sendAudio` no longer `@Synchronized`; guest read-loop exit emits one `.failed`/`Failed` per run with `lostRemotely` captured before `close()` (iOS) and `isRunActive(epoch)` + `emitFailedOnce` (Android); pre-authentication credential rejection stays log-only (ADR-044, RSK-3); test accessors `connectedClientDescriptors`/`guestSocketDescriptor`/`acceptedClientSockets()`.
- Both `ChannelService`s: guest audio-lane events routed through `handleGuestAudioSessionEvent` into the control-lane handler; iOS `pendingAudioLaneFailure` for the CONNECTING race; `consecutiveAudioLaneFailures` with `failGuestSession("Audio connection lost repeatedly")` at 5 (DSCN-19), reset on the first PCM buffer of a run; Android `audioEngine.playbackFailureHandler` → `tourFeatureError`.
- `AudioEngine.kt`: `PcmPlaybackSink`/`PlaybackWriter`/`PlaybackWriteOutcome`, short-write and error counters, `playbackFailureHandler`; `AudioEngine.swift`: tap-floor comment only (DSCN-5).
- `scripts/verify_tour_session.sh`: `EXPECTED_PLAYOUT` parity gate after `EXPECTED_FAULTS`; NODELAY, encode-worker, `@Synchronized sendAudio`, and playout-label audits (one `rg -q` per file) after the cooperative-pool audit.

Commands and results:

1. Fail-before (cores, compile form): `DEVELOPER_DIR=... swift build --build-tests --disable-sandbox --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereFixG3/swift` and `cd Android && JAVA_HOME=... ./gradlew :tour-session-core:compileTestKotlin -q` with the updated core tests against the unchanged cores
   - Result: Swift `SessionProtocolTests.swift:425:24: error: value of type 'EncodedAudioJitterBuffer' has no member 'popForPlayout'` (ten sites through :461); Kotlin `SessionProtocolTest.kt:415:22 Unresolved reference 'EncodedAudioPlayoutDecision'`, `:415:63 Unresolved reference 'popForPlayout'` (twenty sites through :486). `popReady` returned nil/null on a below-target gap, so the `.conceal(missingSequence: 3)` / `Conceal(3)` assertions had no equivalent before the change.
2. After the core change: `swift test ... --filter 'clockedPlayout|realtimeAudioBuffers'` → 2 tests passed; `swift build ... --product tour-session-swift` then `tour-session-swift playout` → `w,w,f1,f2,w,c3,f4,f10,f11,w`. `./gradlew :tour-session-core:test --tests 'com.aessam.toursession.SessionProtocolTest' :tour-session-cli:installDist` → `SessionProtocolTest` 22 tests, 0 failures; `tour-session-cli playout` → identical string.
3. Fail-before (transports, runtime form): the core, fixture, and CLI edits were stashed (`git stash push -- Packages/TourSessionCore Android/tour-session-core Android/tour-session-cli`) so the unchanged transports compiled; only the behavior-free test accessors were added to `UDPAudioPlane.swift`/`.kt`. `DEVELOPER_DIR=... xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG3/ios test -only-testing:GetOverHereTests/LocalSessionTransportTests`
   - Result: exit 65, 14 tests, 2 failed. `helloAndAudioRoundtrip`: `Expectation failed: tcpNoDelay(fd: try #require(guest.guestSocketDescriptor)) != 0`, `Expectation failed: tcpNoDelay(fd: try #require(guide.connectedClientDescriptors.first)) != 0`, `Expectation failed: deliveryQueueLabel == "audio.tcp.playout"` (delivered from `audio.tcp.guest`). `guestAudioLaneReportsGuideClose`: `Caught error: .expired` after 3 s (no event on read-loop exit). `guestAudioLaneStaysSilentOnLocalStop` and `audioLaneWrongCodeStaysSilent` passed on the old tree, as predicted (regression guards). This run took over ten minutes of wall time on a fresh derived-data path (simulator boot and test-host launch); later runs on the same path took about a minute.
   - `cd Android && JAVA_HOME=... ./gradlew :app:testDebugUnitTest --tests com.aessam.comeoverhere.LocalSessionTransportTest --continue -q` → 11 tests, 2 failed: `guestAudioLaneReportsGuideClose` (`Guest audio lane did not report the guide close`), `goh2HelloRegistersGuestAndRealtimePayloadArrives` (`guest socket keeps Nagle`; the encode-thread and playout-thread assertions sit behind it). Stash popped afterwards.
4. Fail-before (new test files, compile form): `git stash push -- Android/app/src/main/java/com/aessam/comeoverhere/service/AudioEngine.kt` then `./gradlew :app:compileDebugUnitTestKotlin -q` → the main source set fails first on `ChannelService.kt:184:21 Unresolved reference 'playbackFailureHandler'`, so the compiler never reached `PlaybackWriterTest.kt`; stash popped. `PlaybackWriterTest.kt`, `PlayoutClockTests.swift`, and `PlayoutClockTest.kt` reference types (`PcmPlaybackSink`, `PlaybackWriter`, `PlaybackWriteOutcome`, `PlayoutClock`) that did not exist at HEAD, and every attempt to compile them against the pre-change sources fails earlier in the main target (this item and the removed `popReady` in item 1), so their fail-before is by construction rather than a captured test-target diagnostic.
5. After the transport, engine, and service changes: `DEVELOPER_DIR=... xcodebuild ... -derivedDataPath /tmp/GetOverHereFixG3/ios test -only-testing:GetOverHereTests/LocalSessionTransportTests -only-testing:GetOverHereTests/PlayoutClockTests -only-testing:GetOverHereTests/SocketFrameIOTests -only-testing:GetOverHereTests/AudioEngineTests -only-testing:GetOverHereTests/NativeRealtimeAudioCodecTests`
   - Result: exit 0, `Test-GetOverHere-2026.09.03_20-55-32--0700.xcresult` totalTestCount 20, passedTests 20, failedTests 0 (the log carries the known warning-only line `error: the following command failed with exit code 0 but produced no further output` from `TourAssetCacheTests.swift`, unchanged by G3).
   - `./gradlew :app:testDebugUnitTest --tests com.aessam.comeoverhere.LocalSessionTransportTest --tests com.aessam.comeoverhere.PlaybackWriterTest --tests com.aessam.comeoverhere.PlayoutClockTest --tests com.aessam.comeoverhere.BoundedSocketFrameWriterTest --continue -q` → `LocalSessionTransportTest` 11, `PlaybackWriterTest` 4, `PlayoutClockTest` 2, `BoundedSocketFrameWriterTest` 1; 0 failures.
6. Emulator (DSCN-9): `adb logcat -c; cd Android && JAVA_HOME=... ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.AudioLaneReconnectTest,com.aessam.comeoverhere.NativeRealtimeAudioCodecTest; adb logcat -d -s AudioLaneReconnectTest ChannelService UDPAudioPlane LocalControlPlane`
   - Result: `Starting 4 tests on GetOverHere_API_36(AVD) - 16`, `Finished 4 tests`, BUILD SUCCESSFUL in 21s; `audioLaneLossSchedulesReconnect` 6.394 s pass, `nativeCodecCrossesEncryptedRealtimeTransport` 2.5 s pass, `opusAndAacLcEncodeAndDecodeNativePcm16Frames` 0.252 s pass, `nativeCapabilitiesMapToSessionNegotiationBits` 0.002 s pass. Logcat: `Published local channel` → `Found local service` → `Resolved local channel` → `Discovered megaphone` → `Discovered in-process guide channel; hostIP present=true` → `Joined megaphone` → `validated guest session` / `authenticated GOH2 session joined` → `Guest connected on control and audio lanes; closing only the audio lane` → `TCP receive failed (IllegalStateException)` → `Session reconnect attempt 1` → `Guest scheduled reconnect after audio-lane loss: reconnectAttempt=1` → `Left channel`. The in-process guide channel was discovered through real NSD (a second `LocalControlPlane` publishing from the test), which is why this proof exists only on the emulator: `LocalControlPlane` needs `NsdManager`, and `ChannelService.channels` is filled only by discovery.
7. `scripts/verify_no_plaintext_session_paths.sh` → `Encrypted session-path audit passed`.
8. `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG3/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG3/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG3/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG3/verifier-ios-modules scripts/verify_tour_session.sh`
   - Result: all nine stages passed. Stage 1: 34 Swift tests in 2 suites. Stage 2: Kotlin core tests and CLI install. Stages 3/4: exact bytes and cross-decodes unchanged. Stage 5: `faults`, `playout` (`w,w,f1,f2,w,c3,f4,f10,f11,w` on both sides), `focus`, `auth`, `recovery`, and the new NODELAY / encode-worker / playout-label audits. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: `:app:testDebugUnitTest` 15 classes, 44 tests, 0 failures, `assembleDebug` built. Stage 9: `Test-GetOverHere-2026.09.03_20-58-26--0700.xcresult` totalTestCount 49, passedTests 49, failedTests 0. Final output: `Tour session verification passed`.

9. Review fix: `handleGuestAudioSessionEvent` on iOS initially stored a pending audio-lane failure only while `.connecting`, so a refused audio connect during a reconnect cycle (state `.reconnecting`, guide audio port still down) would have been discarded and the following control `.connected` would have produced a mute CONNECTED guest again. Changed to `case .connecting, .reconnecting: pendingAudioLaneFailure = message`; re-ran the same `scripts/verify_tour_session.sh` invocation as item 8
   - Result: all nine stages passed. Stage 1: 34 Swift tests. Stages 2, 7, and 8 were Gradle up-to-date (no Android input changed since item 8; `:app:testDebugUnitTest` results on disk: 15 classes, 44 tests, 0 failures). Stage 9: `Test-GetOverHere-2026.09.03_21-06-05--0700.xcresult` totalTestCount 49, passedTests 49, failedTests 0. Final output: `Tour session verification passed`.

Not run this round: the iOS `ChannelService`-level `audioLaneLossSchedulesReconnect` from the plan. `ChannelService.scheduleReconnect` requires `activeChannel`, `channels` is `private(set)` and filled only by Bonjour discovery, and the DSCN-23 `NetworkCoordinator` injection seam is G4's; a real-Bonjour simulator test would resolve the Mac's LAN address rather than loopback and make the gate depend on Wi-Fi state. Handed to G4 with `LifecycleControlPlane.emit(.channelAnnounce)`; the transport-level tests plus the Android emulator proof are the G3 evidence.

## 2026-09-02 — G4 lifecycle: startup ordering, discovery-driven reconfiguration, terminal paths, counts and audio focus, handshake bound

Environment (run on 2026-09-04): Apple M4 Max, macOS 27.0, Xcode 27.0 (27A5218g) at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` (`DEVELOPER_DIR`), Apple Swift 6.4 (swiftlang-6.4.0.25.4), `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`, simulator `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG4/ios`, gate derived data `/tmp/GetOverHereFixG4/verifier-ios`, gate Swift scratch `/tmp/GetOverHereFixG4/verifier-swift`. Android emulator `GetOverHere_API_36` (AVD, `emulator-5554`, Android 16, API 36, arm64-v8a), already booted. No physical device. Every xcodebuild invocation ran alone; gradle runs overlapped only with xcodebuild, never with another gradle run.

Implementation:

- FND-2 (ADR-046): synchronous throwing lane start on both platforms (`SessionControlTransport.startGuide() throws`, `SessionAssetTransport.startGuide() throws`, `AudioPlane.startBroadcasting throws` + `AudioPlaneStartError`; Kotlin `IllegalStateException`, synchronous `AudioEngine.startCapture()` preflight); `startGuideSession` orders control → asset → audio → capture → commit → publish; `rollbackFailedGuideSession` clears every lane and broadcasts `channelEnded` on both platforms; Android `BroadcastProcessor` constructed after the bind (DSCN-28).
- FND-6 (DSCN-11): `restartGuestTransports(channel:)` on both platforms replaces the discovery-driven `joinChannel` and the reconnect body; never `clearSession`, never a second stretch.
- FND-8 (ADR-048): `credentialRejected` events sourced only from the AEAD failure or the proof mismatch (Kotlin `SessionFrameAuthenticationException` subtype, DSCN-26); `failGuestSession` at control version mismatch, credential rejection, and reconnect exhaustion; `sendLeave() async` / `suspend fun sendLeave()` with the deferred `stopCurrentActivity()` under the `sessionAttempt` guard (DSCN-20, DSCN-27); iOS `terminate()`, `AppCoordinator.stop()`, `willTerminateNotification`; DSCN-13 informational guide branch; stale-attempt discard log lines in both ChannelServices (DSCN-28).
- FND-13: `TourControlService.connectedGuestCount` (set semantics) and `ChannelService.connectedGuestCount`/`speakerFeedbackWarning` on both platforms with the UI label `"<n> connected · <m> audio"` and the guest warning; iOS `installCaptureTap`, converter rebuild on route/config change, interruption observer with the pure `interruptionAction(for:)` / `needsConverterRebuild(current:converterInput:)`, capture-end `"Microphone capture stopped"` (DSCN-12); Android `AudioFocusRequest`, `ACTION_AUDIO_BECOMING_NOISY` receiver, `onOutputForcedPrivate` / `onAudioFocusLost` wiring.
- RSK-1 (ADR-047): `HandshakeSlots` (iOS) / `Semaphore` (Android) on all four accept loops, released when the handshake returns or throws; bound calibrated to 32 (see item 6).
- Test seams (DSCN-23): iOS `AudioEngineInterface`, `NetworkCoordinator.init(displayName:controlPlane:audioPlane:)`, `ChannelService(..., reconnectBaseDelay:)`; Android `AudioEngineInterface`, `LocalGuidanceInterface`, `NetworkCoordinator(controlPlane, udpAudio, scope)`, `ChannelService(..., reconnectBaseDelayMillis)`. Shared doubles in `ChannelServiceTestDoubles.swift` / `.kt` (`Lifecycle*`, `FakeAudioEngine`, `FakeLocalGuidance`).
- Reconciled ADR-044 and LessonsLearned 54 with the committed `pendingAudioLaneFailure` behavior (`.connecting` or `.reconnecting`, DSCN-28).

Commands and results:

1. Runtime fail-before (RSK-1), the only new tests that compile against the untouched transports: `iOS/GetOverHereTests/HandshakeBoundTests.swift` and `Android/app/src/test/.../HandshakeBoundTest.kt` written first (8 silent sockets plus a ninth at that time).
   - `cd Android && JAVA_HOME=... ./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.HandshakeBoundTest' --continue -q` → `2 tests completed, 2 failed`, both `ninth pending handshake must be closed without a challenge expected:<-1> but was:<0>` (the ninth socket read the challenge's first length byte). Exit 1.
   - `DEVELOPER_DIR=... xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG4/ios test -only-testing:GetOverHereTests/HandshakeBoundTests` → exit 65; both lanes `Expectation failed: rawReceiveByte(fd: ninth, timeoutSeconds: 1) == 0` at `HandshakeBoundTests.swift:65`.
2. Compile-form fail-before, Kotlin: `git stash push -- Android/tour-session-core/src/main Android/app/src/main`, then `./gradlew :tour-session-core:compileTestKotlin :app:compileDebugUnitTestKotlin --continue -q`, then `git stash pop`
   - Result: exit 1 with 58 diagnostics, among them `SessionProtocolTest.kt:84 Unresolved reference 'SessionFrameAuthenticationException'`, `ChannelServiceLifecycleTest.kt:64 Argument type mismatch: actual type is 'LifecycleControlPlane', but 'Context' was expected`, `:67 actual type is 'FakeAudioEngine', but 'AudioEngine' was expected`, `:72 actual type is 'FakeLocalGuidance', but 'LocalGuidanceService' was expected`, `:234 Unresolved reference 'CredentialRejected'`, `:293 Unresolved reference 'connectedGuestCount'`, `:317 Unresolved reference 'speakerFeedbackWarning'`, `ChannelServiceTestDoubles.kt:15 Unresolved reference 'AudioEngineInterface'`, `:17 Unresolved reference 'LocalGuidanceInterface'`, `:173 'sendLeave' overrides nothing`.
3. Compile-form fail-before, iOS: `git stash push -- iOS/GetOverHere`, then `DEVELOPER_DIR=... xcodebuild ... -derivedDataPath /tmp/GetOverHereFixG4/ios build-for-testing`, then `git stash pop`
   - Result: exit 65 (`3 failures`; the compiler stops at the first failing file): `ChannelServiceTestDoubles.swift:63 type 'LifecycleAudioPlane' does not conform to protocol 'AudioPlane'` (throwing `startBroadcasting`), `:120 type 'LifecycleControlTransport' does not conform to protocol 'SessionControlTransport'` (throwing `startGuide`, `sendLeave`), `:204 type 'LifecycleAssetTransport' does not conform to protocol 'SessionAssetTransport'`, `:267 cannot find type 'AudioEngineInterface' in scope`. The remaining seam-dependent tests (`credentialRejected`, `connectedGuestCount`, `speakerFeedbackWarning`, `terminate()`, `reconnectBaseDelay:`) sit behind those files and fail by construction on the old tree.
4. Kotlin focused after the change: `./gradlew :tour-session-core:test --tests 'com.aessam.toursession.SessionProtocolTest' :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.ChannelServiceLifecycleTest' --tests 'com.aessam.comeoverhere.HandshakeBoundTest' --tests 'com.aessam.comeoverhere.GuestHandshakeOutcomeTest' --tests 'com.aessam.comeoverhere.PresentationServiceTest' --tests 'com.aessam.comeoverhere.LocalSessionTransportTest' --continue -q`
   - Result (after two compile fixes in the new test files: JUnit 4 `assertNotNull` returns Unit; a `var listenerOutput` in `FakeAudioEngine` clashed with `setListenerOutput` on the JVM): `SessionProtocolTest` 23 tests (incl. `anotherTourCredentialFailsAsTheAuthenticationSubtype`), `ChannelServiceLifecycleTest` 11, `HandshakeBoundTest` 2, `GuestHandshakeOutcomeTest` 1, `PresentationServiceTest` 7, `LocalSessionTransportTest` 11; 0 failures.
   - First full `:app:testDebugUnitTest` afterwards showed one flake: `captureStreamEndSurfacesError` `expected:<1> but was:<0>` at the `audioPlane.sent.size` assertion. Root cause: the capture collector is a `launch` nested inside the credential-hop coroutine, and `UnconfinedTestDispatcher` runs a nested launch only after the outer body completes, so the test thread could observe `BROADCASTING` before the first frame was forwarded. The test now polls for the frame and the error text. Stability: `./gradlew :app:cleanTestDebugUnitTest :app:testDebugUnitTest --tests ChannelServiceLifecycleTest --tests HandshakeBoundTest --tests GuestHandshakeOutcomeTest` three times → 11/11, 11/11, 11/11.
5. Android full: `./gradlew :app:cleanTestDebugUnitTest :app:lintDebug :app:testDebugUnitTest :tour-session-core:test --continue -q`
   - Result: `lintDebug` 0 errors, 167 warnings (`ContextCompat.registerReceiver` with `RECEIVER_NOT_EXPORTED` and `AudioFocusRequest` pass the API-26 floor lint); `:app:testDebugUnitTest` 18 classes, 59 tests, 0 failures; `SessionProtocolTest` 23 tests, 0 failures.
6. iOS focused: `DEVELOPER_DIR=... xcodebuild ... -derivedDataPath /tmp/GetOverHereFixG4/ios test -only-testing:GetOverHereTests/ChannelServiceLifecycleTests -only-testing:GetOverHereTests/HandshakeBoundTests -only-testing:GetOverHereTests/GuestHandshakeOutcomeTests -only-testing:GetOverHereTests/AudioEngineTests -only-testing:GetOverHereTests/PresentationServiceTests -only-testing:GetOverHereTests/LocalSessionTransportTests -only-testing:GetOverHereTests/HybridSessionTransportsTests`
   - Run 1: `Test run with 42 tests in 7 suites failed after 22.547 seconds with 2 issues`. (a) `audioLaneLossSchedulesReconnect` reached `.reconnecting(attempt: 1)` but my extra expectation on `tourFeatureError` was wrong: iOS `scheduleReconnect` logs the reason and Android stores it; the assertion now checks that the lane restart waits for the backoff. (b) The pre-existing `controlLaneScalesBeyondProcessorCount` (24 simultaneous control guests) timed out (`Caught error: .expired` after 8 s) with the handshake bound at 8: the accept loop dequeues a burst faster than the handshakes complete, so 16 legitimate guests were closed. The bound is calibrated to 32 on all four lanes (ADR-047); `HandshakeBoundTests`/`HandshakeBoundTest` open 32 silent sockets and assert the 33rd is closed and the next is admitted after one release.
   - Run 2 (same command): `Test run with 42 tests in 7 suites passed after 14.621 seconds`, `Test-GetOverHere-2026.09.04_08-21-57--0700.xcresult`. Suites: ChannelService lifecycle 13, HandshakeBoundTests 2, GuestHandshakeOutcomeTests 1, Audio engine 3, Presentation service 7, LocalSessionTransportTests 14 (incl. the 24-guest burst and the rewritten wrong-code and unconfigured-start tests), Hybrid session transports 2.
7. Emulator (FND-13, RSK-17): `adb logcat -c; cd Android && JAVA_HOME=... ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.AudioEngineFocusTest; adb logcat -d -s AudioEngine AudioEngineFocusTest TestRunner` (adb from `$HOME/Library/Android/sdk/platform-tools`)
   - Run 1 (two tests): `losingAudioFocusInvokesCallback` passed (logcat `E AudioEngine: Audio focus lost` 1 ms after the competing `AUDIOFOCUS_GAIN` request); `audioBecomingNoisyForcesPrivateOutput` fired its callback (logcat `Output route=SPEAKER, applied=true` → `Audio output became noisy; forcing private output`) but was reported SKIPPED because the earpiece `assumeTrue` followed the callback assertion in the same method. Split into two tests.
   - Run 2: `Starting 3 tests on GetOverHere_API_36(AVD) - 16`, BUILD SUCCESSFUL in 9s: `losingAudioFocusInvokesCallback` pass, `audioBecomingNoisyForcesPrivateOutput` pass (callback fired and `appliedListenerOutput == PRIVATE_AUDIO`), `audioBecomingNoisyRoutesToEarpiece` SKIPPED by assumption (`no built-in earpiece on this device; route assertion needs hardware`; logcat `E AudioEngine: No communication device for PRIVATE_AUDIO`). BLOCKED per DSCN-14: the earpiece route assertion needs a physical device; the exact command above reruns it.

8. Gate, run 1: `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG4/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG4/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG4/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG4/verifier-ios-modules scripts/verify_tour_session.sh`
   - Result: all nine stages passed. Stage 1: 34 Swift tests in 2 suites. Stage 2: Kotlin core tests and CLI install. Stages 3/4/5: exact bytes, cross-decodes, `faults`, `playout`, `focus`, `auth`, `recovery`, and every source audit unchanged (G4 changes no wire bytes). Stage 6: `Encrypted session-path audit passed`. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: `:app:testDebugUnitTest` 18 classes, 59 tests, 0 failures, `app-debug.apk` built. Stage 9: `Test-GetOverHere-2026.09.04_08-23-50--0700.xcresult` totalTestCount 68, passedTests 68, failedTests 0. Final output: `Tour session verification passed`. The log carried three warning-only `error: the following command failed with exit code 0 but produced no further output` lines (G2/G3 saw one from `TourAssetCacheTests.swift`); two were new: `ChannelServiceTestDoubles.swift` evaluated `PeerInfo(...)` default arguments outside the main actor, `AudioEngineTests` compared the main-actor-isolated `Equatable` conformance of `CaptureInterruptionAction` from a nonisolated test, and the moved tap line discarded the `withLock` result. Fixed (nullable defaults built inside the actor, `nonisolated enum CaptureInterruptionAction: Equatable, Sendable`, `_ = $0?.yield(data)`).
9. Gate, run 2 on the final tree (same command)
   - Result: all nine stages passed; stage 1 34 Swift tests; stage 8 18 classes, 59 tests, 0 failures; stage 9 `Test-GetOverHere-2026.09.04_08-25-55--0700.xcresult` totalTestCount 68, passedTests 68, failedTests 0; no `error:` line in the log. Final output: `Tour session verification passed`.

10. Emulator regression for the rewritten paths (after gate run 2): `adb logcat -c; cd Android && JAVA_HOME=... ./gradlew :app:connectedDebugAndroidTest '-Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.AudioLaneReconnectTest,com.aessam.comeoverhere.AudioEngineRoutingTest#voiceCommunicationCaptureProducesAFrame'; adb logcat -d -s AudioLaneReconnectTest ChannelService AudioEngine TestRunner`
   - Result: `Starting 2 tests on GetOverHere_API_36(AVD) - 16`, `Finished 2 tests`, BUILD SUCCESSFUL in 11s. `audioLaneLossSchedulesReconnect` (G3's real-NSD ChannelService proof, now through `scheduleReconnect` → `restartGuestTransports`): logcat `Discovered in-process guide channel; hostIP present=true` → `Joined megaphone` → `Guest connected on control and audio lanes; closing only the audio lane` → `Session reconnect attempt 1` → `Guest scheduled reconnect after audio-lane loss: reconnectAttempt=1` → `Left channel`. `voiceCommunicationCaptureProducesAFrame` (the synchronous `startCapture()` preflight against a real `AudioRecord`): `Capture started: 16000Hz mono PCM16` → `First capture packet emitted: 320 bytes`. The sibling earpiece test in `AudioEngineRoutingTest` was excluded by the method filter; it belongs to G6 (DSCN-14).

Not automated, with justification: the iOS `willTerminateNotification` modifier (three lines in `GetOverHereApp`) cannot be raised from a unit test; `ChannelService.terminate()` behind it is unit-tested (`terminateClearsAllLanesForGuideAndGuest`), and the device check is "end the app while broadcasting, confirm the guest receives the authenticated leave" on the P3 physical checklist. The iOS route-change and interruption observers need real audio hardware (simulator capture is unsupported by design); their decisions are the pure `interruptionAction(for:)` / `needsConverterRebuild(current:converterInput:)` pinned in `AudioEngineTests`, and headset plug/unplug plus an incoming call are P3 physical checklist items. The Android `ACTION_AUDIO_BECOMING_NOISY` receiver delivery itself is not exercised (`AudioEngineFocusTest` calls `handleAudioBecomingNoisy()` directly); unplugging wired headphones during a tour is the physical check. RSK-1 release on the 5 s receive-timeout path shares the `Result`/`finally` release with the EOF path that `HandshakeBoundTests` exercises and is not timed separately because it would add more than 5 s per lane per platform to the gate.
