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

### 2026-09-04 — G4 repair: dedicated lane-ownership generation, Kotlin permit release, DSCN-27 catch

Environment: same machine and toolchain as the G4 section above (Xcode 27.0 beta via `DEVELOPER_DIR`, Android Studio JBR `JAVA_HOME`, `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG4/ios`, gate `GOH_*` paths under `/tmp/GetOverHereFixG4/verifier-*`). No physical device; no emulator run needed (no instrumented test touched). One xcodebuild at a time; gradle overlapped only with xcodebuild.

Defects (verification of commit 70affec): (1) major, FND-8: the deferred End Tour teardown compared the DSCN-20 `sessionAttempt`, which every no-op `leaveChannel()`/`terminate()` and every invalid `joinChannel` also bumps, so a second End Tour tap inside the 2 s flush window logged `Skipping the deferred lane teardown` and never called `clearSession()` on control/asset/audio. (2) minor, RSK-1 Kotlin: `socket.soTimeout = 5_000` (and `getInputStream()` on the realtime lane) ran between the accept loop's `tryAcquire` and the `finally` that releases the permit. (3) minor, DSCN-27: Kotlin `leaveChannel()` used `runCatching` around the suspend `endGuideSession()`, swallowing `CancellationException`.

Implementation: `private var sessionGeneration: UInt64` / `Long` on both `ChannelService`s, bumped in `startGuideSession`/`startGuestSession` immediately before the lanes are configured, in `stopCurrentActivity()`, and in `leaveChannel()`/`terminate()` after the `activeChannel` guard; `leaveChannel()` captures it and the deferred task compares it. `sessionAttempt` is unchanged. Kotlin `handleGuest`/`authenticateAndMonitor`: `socket.soTimeout = 5_000` moved inside the released `try`; the realtime lane takes its post-hello `InputStream` after the handshake (`authenticateGuest` opens its own). Kotlin `leaveChannel()`: `try { endGuideSession() } catch (CancellationException) { throw } catch (Exception) { Log.e(type name) }`. ADR-047, ADR-048, and LessonsLearned 61 corrected.

Commands and results:

1. Fail-before, Kotlin (new `endTourTeardownSurvivesANoOpLeave` on the unrepaired tree): `cd Android && JAVA_HOME=... ./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.ChannelServiceLifecycleTest' --continue -q`
   - Result: exit 1, `12 tests completed, 1 failed`; `endTourTeardownSurvivesANoOpLeave`: `java.lang.AssertionError: lanes cleared after delivery despite the no-op leave expected:<1> but was:<0>`.
2. Fail-before, iOS (new `endTourTeardownSurvivesANoOpLeave`): `DEVELOPER_DIR=... xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG4/ios test -only-testing:GetOverHereTests/ChannelServiceLifecycleTests`
   - Result: exit 65, `Test run with 14 tests in 1 suite failed after 7.366 seconds with 1 issue`; `ChannelServiceLifecycleTests.swift:171: Caught error: .expired("lanes cleared after delivery despite the no-op leave")` after the 5 s wait.
3. Kotlin focused after the repair: `./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.ChannelServiceLifecycleTest' --tests 'com.aessam.comeoverhere.HandshakeBoundTest' --tests 'com.aessam.comeoverhere.LocalSessionTransportTest' --tests 'com.aessam.comeoverhere.GuestHandshakeOutcomeTest' --continue -q`
   - Result: exit 0; `ChannelServiceLifecycleTest` 12/12, `HandshakeBoundTest` 2/2, `LocalSessionTransportTest` 11/11, `GuestHandshakeOutcomeTest` 1/1, 0 failures.
4. iOS focused after the repair (same command as item 2)
   - Result: exit 0, `Test run with 14 tests in 1 suite passed after 2.240 seconds` (`endTourTeardownSurvivesANoOpLeave` 0.132 s), `Test-GetOverHere-2026.09.04_12-44-42--0700.xcresult`.
5. Gate: `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG4/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG4/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG4/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG4/verifier-ios-modules scripts/verify_tour_session.sh`
   - Result: exit 0, all nine stages passed. Stage 1: 34 Swift tests in 2 suites. Stage 6: `Encrypted session-path audit passed`. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: `:app:testDebugUnitTest` 18 classes, 60 tests, 0 failures, `app-debug.apk` built. Stage 9: `Test-GetOverHere-2026.09.04_12-54-24--0700.xcresult` totalTestCount 69, passedTests 69, failedTests 0. No `error:` line in the log. Final output: `Tour session verification passed`.

Not automated, with justification: the RSK-1 Kotlin permit leak needs a `SocketException` from `setSoTimeout` on a socket closed between `accept()` and the worker's first statement, a sub-millisecond race that cannot be induced deterministically from a test; the repair is by construction (the `finally` now starts at the worker's first statement) and `HandshakeBoundTest` still proves release on the return/EOF path. The DSCN-27 `CancellationException` rethrow is verified by inspection; the existing `endTourFlushesLeaveOffMainAndClearsAfterDelivery` covers the non-cancelled flush.

Follow-up in the same repair (reviewer finding on the first cut): the deferred teardown's `stopCurrentActivity()` bumped `sessionAttempt`, so a Create/Join whose PBKDF2 stretch was still in flight when the flush completed was discarded as stale (`Discarding a stale guide credential`, info log only). On 70affec that ordering worked because the attempt mismatch skipped the teardown. Repair: `stopCurrentActivity(discardingPendingStretch: Bool = true)` / `(discardingPendingStretch: Boolean = true)` guards the `sessionAttempt` bump; only the deferred End Tour teardown passes `false`. ADR-048 item (3) records it.

6. Fail-before, Kotlin (new `endTourTeardownDoesNotDiscardAFollowingCreate` on the first-cut tree): same command as item 1
   - Result: exit 1, `13 tests completed, 1 failed`; `java.lang.AssertionError: Timed out waiting for second tour broadcasting after the deferred teardown` (5 s).
7. Fail-before, iOS (same test): same command as item 2
   - Result: exit 65, `Test run with 15 tests in 1 suite failed after 7.825 seconds with 1 issue`; `ChannelServiceLifecycleTests.swift:201: Caught error: .expired("second tour broadcasting after the deferred teardown")`.
8. Kotlin focused after the follow-up: `./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.ChannelServiceLifecycleTest' --continue -q`
   - Result: exit 0, `ChannelServiceLifecycleTest` 13/13 (`endTourTeardownDoesNotDiscardAFollowingCreate` 0.125 s, `endTourTeardownSurvivesANoOpLeave` 0.069 s).
9. iOS focused after the follow-up (same command as item 2)
   - Result: exit 0, `Test run with 15 tests in 1 suite passed after 3.130 seconds` (`endTourTeardownDoesNotDiscardAFollowingCreate` 0.307 s), `Test-GetOverHere-2026.09.04_13-11-33--0700.xcresult`.
10. Gate, run 2 on the final tree (same command as item 5)
   - Result: exit 0, all nine stages passed. Stage 1: 34 Swift tests in 2 suites. Stage 6: `Encrypted session-path audit passed`. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: `:app:testDebugUnitTest` 18 classes, 61 tests, 0 failures, `app-debug.apk` built. Stage 9: `Test-GetOverHere-2026.09.04_13-12-35--0700.xcresult` totalTestCount 70, passedTests 70, failedTests 0. No `error:` line in the log. Final output: `Tour session verification passed`. The verifier reads no markdown file, so the ExperimentLog append after this run does not change its outcome.

## 2026-09-02 — G5 assets: cache repair, per-asset isolation, in-flight cap, bounded re-request, inactivity deadline, guest error surfacing

Environment (run on 2026-09-04): Apple M4 Max, macOS 27.0, Xcode 27.0 (27A5218g) at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` (`DEVELOPER_DIR`), `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`, simulator `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG5/ios`, gate derived data `/tmp/GetOverHereFixG5/verifier-ios`, gate Swift scratch `/tmp/GetOverHereFixG5/verifier-swift`. JVM unit tests only on Android (no instrumented test in this group; no emulator or device needed). Every xcodebuild invocation ran alone; gradle runs overlapped only with xcodebuild.

Implementation (ADR-049, FND-9, DSCN-16, DSCN-17):

- Cache repair on both platforms: `readyURL`/`readyFile` deletes a length-mismatched `complete/` entry, prints one stderr line, and returns `nil`/`null`; `resumeOffset` deletes an oversized partial, prints one line, and returns 0. `AssetCacheError.lengthMismatch` kept with a deprecation comment (DSCN-17). Kotlin `AssetCacheException` is `open`; new `AssetChecksumMismatchException` subtype thrown only when the partial was deleted.
- Guest scheduler in `TourAssetTransferService` (both): `pendingHashes`/`inFlightHashes`/`transferAttempts`/`inFlightDeadlines`, `pumpRequests` (slot reserved before the cache call, stderr line on a dropped hash), `finishTransfer`, `resetGuestTransferQueue` on `.disconnected`/`Disconnected` and `stop()` (Android routes the `stop()` reset through the worker for FIFO ordering), per-asset isolation in `handleGuestManifest`, one checksum re-request from offset 0 then FAILED, late-chunk drop for a hash no longer in flight, and the DSCN-16 deadline armed in `sendRequest` (iOS main-actor `Task`; Android `worker` is now `newSingleThreadScheduledExecutor` with the same `tour-asset-transfer` thread name). Constants `maxInFlightRequests = 2`, `maxTransferAttempts = 2`, `inFlightDeadline = 15 s` / `MAX_IN_FLIGHT_REQUESTS`, `MAX_TRANSFER_ATTEMPTS`, `IN_FLIGHT_DEADLINE_MILLIS = 15_000`; deadline detail `no chunk received within 15 s`. Test seam: `init(transport:cache:inFlightDeadline:)` / constructor `inFlightDeadlineMillis` defaulting to the contract constant; production call sites unchanged.
- iOS `ChannelService` stores the asset `.failed` message in `tourFeatureError`; guest label (`connectionState != .failed`) below the speaker warning in `ChannelDetailView.guestView`; the same `Text` below G4's warning in `ChannelScreen.ListenerView` using G1's `tourFeatureError` parameter (no new parameter).

Commands and results:

1. Fail-before, Android (new tests written first; the deadline test excluded because it needs the new constructor parameter): `cd Android && JAVA_HOME=... ./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.TourAssetCacheTest' --tests 'com.aessam.comeoverhere.TourAssetTransferServiceTest' --tests 'com.aessam.comeoverhere.ChannelServiceLifecycleTest' --continue -q`
   - Result: exit 1, `22 tests completed, 6 failed`. `TourAssetCacheTest` 3 tests, 2 failed: `lengthMismatchedCompleteEntryIsDeletedAndReportedMissing` (`AssetCacheException: Asset length mismatch: expected 18, got 10`), `oversizedPartialIsDeletedAndResumeRestartsAtZero` (`... expected 18, got 30`). `TourAssetTransferServiceTest` 5 tests, 4 failed: `interruptedTransferResumesAndReportsVerifiedParticipantReadiness` (`Guest assets were not all ready: []`, the corrupt map entry aborted the manifest loop), `manifestRequestsAreCappedAtTwoInFlight` (`Timed out waiting for 2 asset requests`), `checksumMismatchIsReRequestedOnceAndRecovers` (`Timed out waiting for 2 asset requests`, no retry), `secondChecksumMismatchSendsFailedStatusAndReleasesSlot` (`request burst exceeded the expected count expected:<2> but was:<3>`, no cap). `disconnectResetsInFlightRequests` passed by construction (no queue existed). `ChannelServiceLifecycleTest` 14/14 including `assetTransferFailureSurfacesInTourFeatureError`, which passes before on Android (ChannelService.kt already stored `event.message`) and is kept as a parity guard.
2. Fail-before, iOS (same test set): `DEVELOPER_DIR=... xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG5/ios -only-testing:GetOverHereTests/TourAssetCacheTests -only-testing:GetOverHereTests/TourAssetTransferServiceTests -only-testing:GetOverHereTests/ChannelServiceLifecycleTests test`
   - Result: exit 65, `Test run with 24 tests in 3 suites failed after 30.962 seconds with 9 issues`. `assetTransferFailureSurfacesInTourFeatureError`: `Caught error: .expired("asset failure surfaced")` after 2 s (tourFeatureError stayed nil). Cache tests: `Caught error: .lengthMismatch(expected: 18, actual: 10)` and `.lengthMismatch(expected: 18, actual: 30)`. Loopback: `.expired("assets ready: [...]")` after 10 s. Cap test and retry test: `.expired("2 asset requests")`. Second-mismatch test: `requests.count == count` failed (3 immediate requests), `f.requests[2].sha256 == f.hash("a")` failed, `.expired("4 asset requests")`. `disconnectResetsInFlightRequests` passed by construction.
3. Compile-form fail-before for the deadline seam, Kotlin: `git stash push -- Android/app/src/main/java/com/aessam/comeoverhere/service/TourAssetTransferService.kt Android/app/src/main/java/com/aessam/comeoverhere/service/TourAssetCache.kt`, then `./gradlew :app:compileDebugUnitTestKotlin --continue -q`, then `git stash pop`
   - Result: exit 1, `TourAssetTransferServiceTest.kt:414:60 Too many arguments for 'constructor(transport: SessionAssetTransport, cache: TourAssetCache): TourAssetTransferService'`. The iOS `unansweredRequestReleasesSlotAfterDeadline` uses the mirror `inFlightDeadline:` argument and fails the same way by construction (not run separately: one more full test-target compile for a diagnostic already shown on the Kotlin twin).
4. Android focused after the change (same command as item 1): run 1 exit 0, `TourAssetCacheTest` 3/3, `TourAssetTransferServiceTest` 6/6 (`manifestRequestsAreCappedAtTwoInFlight` 0.488 s, `unansweredRequestReleasesSlotAfterDeadline` 0.374 s, `secondChecksumMismatchSendsFailedStatusAndReleasesSlot` 0.300 s, loopback 0.126 s, `checksumMismatchIsReRequestedOnceAndRecovers` 0.097 s, `disconnectResetsInFlightRequests` 0.076 s), `ChannelServiceLifecycleTest` 14/14. Run 2 after the assertion change in item 5: exit 0, 3/3, 6/6, 14/14.
5. iOS focused after the change (same command as item 2)
   - Run 1: `Test run with 25 tests in 3 suites failed after 4.046 seconds with 2 issues`; every test passed except `unansweredRequestReleasesSlotAfterDeadline`, whose two ordered assertions (`failedStatuses` as `[a, b]`, first `.failed` event `Asset a: ...`) saw `[b, a]`: the two deadlines expire in the same instant and Swift does not order sibling task resumptions. The behavior was correct (C then D requested in queue order, both FAILED statuses and events present); the assertions on both platforms are now set comparisons.
   - Run 2: exit 0, `Test run with 25 tests in 3 suites passed after 3.917 seconds`, `Test-GetOverHere-2026.09.04_13-34-53--0700.xcresult`. `ChannelService lifecycle` 15 (incl. `assetTransferFailureSurfacesInTourFeatureError` 0.013 s), `Content-addressed tour asset cache` 3, `Tour asset transfer service` 7 (loopback 0.115 s, cap 0.461 s, retry 0.146 s, second mismatch 0.353 s, disconnect reset 0.144 s, deadline 0.414 s).
6. Gate: `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG5/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG5/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG5/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG5/verifier-ios-modules scripts/verify_tour_session.sh`
   - Run 1: exit 0, all nine stages passed. Stage 1: 34 Swift tests in 2 suites. Stages 3/4/5: every byte compare, cross-decode, `faults`, `playout`, `focus`, `auth`, `recovery`, and source audit unchanged (G5 changes no core code and no wire bytes). Stage 6: `Encrypted session-path audit passed`. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: `:app:testDebugUnitTest` 18 classes, 69 tests, 0 failures, `app-debug.apk` built. Stage 9: `Test-GetOverHere-2026.09.04_13-36-03--0700.xcresult` totalTestCount 78, passedTests 78, failedTests 0. Final output: `Tour session verification passed`. The log carried one warning-only `error: the following command failed with exit code 0 but produced no further output` line on the `TourAssetCacheTests.swift` compile, caused by two new Swift 6 isolation warnings: the `inFlightDeadline` default argument read a main-actor static from a nonisolated context (`TourAssetTransferService.swift:91`), and the two new cache tests called the main-actor `FileTourAssetCache` init from nonisolated tests. Fixed: the three new constants are `nonisolated static let`; the two tests are `@MainActor`.
   - Run 2 on the final tree (same command): exit 0, all nine stages passed. Stage 1: 34 Swift tests in 2 suites. Stage 6: `Encrypted session-path audit passed`. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: 18 classes, 69 tests, 0 failures, `app-debug.apk` built. Stage 9: `Test-GetOverHere-2026.09.04_13-37-48--0700.xcresult` totalTestCount 78, passedTests 78, failedTests 0. No `error:` line in the log. Final output: `Tour session verification passed`. The verifier reads no markdown file, so the ExperimentLog append after this run does not change its outcome.

Not automated, with justification: the two guest error labels are SwiftUI/Compose view code with no snapshot harness in either test target; the state they render (`tourFeatureError`) is pinned by `assetTransferFailureSurfacesInTourFeatureError` on both platforms and the FAILED gate reuses G1's `guestStatusText`/`guestConnectionStatusText` path. The late-chunk drop (a chunk arriving after the deadline already reported FAILED) is by construction: every chunk follows a request and every request reserves a slot; producing it in a test would need a guide that answers after 15 s or a second seam, and the guard is one `contains` check with a stderr line.

## 2026-09-02 — G6 tests and hygiene: transport-level fan-out, sender binding, reconnect loop, retired-code deletion, portable verifier, core-parity CI

Environment (run on 2026-09-04): Apple M4 Max, macOS 27.0, Xcode 27.0 beta at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` (`DEVELOPER_DIR`; `xcode-select -p` resolves to the same path), `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` (OpenJDK 21.0.8), simulator `platform=iOS Simulator,name=iPhone 17 Pro`, `-parallel-testing-enabled NO`, focused derived data `/tmp/GetOverHereFixG6/ios`, gate derived data `/tmp/GetOverHereFixG6/verifier-ios`, gate Swift scratch `/tmp/GetOverHereFixG6/verifier-swift`, core-parity Swift scratch `/tmp/GetOverHereCoreParitySwift`. Emulator `emulator-5554` = AVD `GetOverHere_API_36` (SDK 36, `Android SDK built for arm64`), already booted. Every xcodebuild invocation ran alone. The full JVM transport suite never overlapped an xcodebuild test run; the only JVM transport test that did was the Kotlin reconnect mutation (item 5, port 50_040) together with the `BoundedSocketFrameWriterTest` probes (item 8, ephemeral ports) during the first iOS focused run, all disjoint from the iOS ports (50000-50002, 50_031-50_039); every other overlap was a Gradle build, lint, or core-test run or the emulator run, none of which binds those ports.

Implementation (ADR-050, ADR-051, FND-12, FND-14, DSCN-2, DSCN-3, DSCN-14, DSCN-15, DSCN-24, DSCN-25):

- `RawGuestClient` on both platforms (`iOS/GetOverHereTests/RawGuestClient.swift`, `Android/app/src/test/.../RawGuestClient.kt`): an authenticated GOH2 guest that never reads unless asked and stamps any sender ID (port of `authenticateGuide`).
- Transport tests: the 24-guest test now asserts that every guest receives a guide heartbeat (iOS extended, Android new); stalled-peer fan-out (one authenticated raw peer with a 4 KiB / 2 KiB receive window that never reads, eight 512 KiB heartbeats, both healthy guests receive all within 1 s, the stalled peer is evicted within 6 s, a post-eviction heartbeat still arrives, no healthy disconnect); forged guide sender ID (authenticated raw guest seals a heartbeat with `senderID == guideID`: `guestDisconnected`, no `envelopeReceived`, socket closed; Kotlin additionally the exact `Failed("Session: guest connection failed: control envelope is not from the authenticated guest")`); guest reconnect after three guide restarts (fresh `.connected`/`GuestJoined` and a heartbeat per cycle, no `.failed` on either iOS side; Kotlin exactly one guest `Failed` with prefix `Session: guide connection failed:` before each `Disconnected`, none after `Connected`, no guide `Failed`). Ports 50_037-50_039 (iOS), 50_037-50_040 (Android).
- `BoundedSocketFrameWriterTest.kt`: assertions moved off the writer's daemon thread (`stalledGeneration`, `healthyFailure` recorded, asserted on the JUnit thread). `AudioEngineRoutingTest.kt`: the Float32-alignment assertion replaced by the PCM16 10 ms contract (`SAMPLE_RATE / 100 * Short.SIZE_BYTES` = 320 bytes). `AudioEngine.DEFAULT_LISTENER_OUTPUT` (companion, `PRIVATE_AUDIO`) read by `ListenerOutputTest.audioEngineDefaultsToPrivateAudio`; iOS `ListenerOutputTests.engineDefaultRoute` reads `AudioEngine().listenerOutput`.
- Deletion (DSCN-2): 9 iOS files (`BLETransport`, `CompositeTransport`, `L2CAPAudioStream`, `MultipeerTransport`, `MultipeerAudioPlane`, `WiFiHotspotJoiner`, `LeaderElection`, `TransportMessage` in `Core/`, `Models/ChannelMessage`), 17 Android files (`core/BLETransport`, `L2CAPAudioStream`, `NearbyTransport`, `PeerInfo`, `DataTag`, `ChannelMessage`, `LeaderElection`, `WiFiHotspotManager`; `service/ChatService`, `FileShareService`, `WalkieTalkieService`; `ui/AppNavigation`, `ui/chat/*`, `ui/files/*`, `ui/nearby/*`, `ui/walkietalkie/*`) with the four emptied `ui/` directories, and the `HotspotConfiguration` entitlement. Kept: `TransportMessage.kt`, `BLEControlPlane`/`BLEConstants`, Wi-Fi Aware transports, `HybridSessionTransports`, `Logging.swift` categories, `CHANGE_WIFI_STATE`/`CHANGE_NETWORK_STATE`. `verify_no_plaintext_session_paths.sh`: the two Multipeer audits replaced by the retired-path existence audit and the entitlement audit. CLAUDE.md line 16 and AGENTS.md line 17 sentence-only edits.
- Scripts: `verify_tour_session.sh` and the four helper scripts resolve Java as `GOH_ANDROID_JAVA_HOME` → `JAVA_HOME` → JBR and Xcode as `GOH_XCODE_DEVELOPER_DIR` → (`DEVELOPER_DIR`) → `xcode-select -p` → the previous literal; both verifiers print the resolved values. New `scripts/verify_core_parity.sh` (four stages, eleven-subcommand byte compare) and `.github/workflows/core-parity.yml` (`push` to `main`, `pull_request`, `workflow_dispatch`).

Commands and results:

1. Compile-form fail-before, Kotlin (new tests written first, before `DEFAULT_LISTENER_OUTPUT` existed): `cd Android && JAVA_HOME=... ./gradlew :app:compileDebugUnitTestKotlin --continue -q`
   - Result: `BUILD FAILED`; exactly two errors, `ListenerOutputTest.kt:20:64 Unresolved reference 'DEFAULT_LISTENER_OUTPUT'` and `:21:58`; every other new test (`RawGuestClient.kt`, the four transport tests, the `BoundedSocketFrameWriterTest` edit) compiled.
2. Android focused after the constant: `./gradlew :app:testDebugUnitTest --tests com.aessam.comeoverhere.BoundedSocketFrameWriterTest --tests com.aessam.comeoverhere.LocalSessionTransportTest --tests com.aessam.comeoverhere.ListenerOutputTest --continue -q`
   - Result: exit 0. `LocalSessionTransportTest` 15/15 (`twentyFourGuestsAuthenticateAndEachReceivesAControlFrame` 0.062 s, `stalledGuestDoesNotDelayHealthyGuests` 2.069 s, `guideDisconnectsGuestThatForgesGuideSenderId` 0.048 s, `guestReconnectsAfterGuideRestartThreeTimes` 0.884 s), `BoundedSocketFrameWriterTest` 1/1 (0.126 s), `ListenerOutputTest` 2/2.
3. iOS focused, run 1: `DEVELOPER_DIR=... xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG6/ios test -only-testing:GetOverHereTests/LocalSessionTransportTests -only-testing:GetOverHereTests/ListenerOutputTests`
   - Result: exit 65, `Test-GetOverHere-2026.09.04_14-19-46--0700.xcresult`, 19 tests, 18 passed, 1 failed: `guestReconnectsAfterGuideRestartThreeTimes` `Caught error: .streamEnded` at 0.35 s. Cause: the 250 ms negative wait after `guest.stop()` used the task-group timeout as its success path; cancelling a timed-out `AsyncStream` consumer finishes the stream, so the next wait read nil. Fix: the negative wait polls the recorded event log (as the Kotlin twin does) and never consumes the stream. `stalledGuestDoesNotDelayHealthyGuests` passed in 4 s (eviction after two SO_SNDTIMEO periods), `guideDisconnectsGuestThatForgesGuideSenderID` 0.11 s, the extended 24-guest test 0.099 s.
4. iOS focused, run 2 (same command, after the fix and after the DSCN-2 deletions and the entitlement edit, so it also proves the iOS tree compiles without the retired files)
   - Result: exit 0, `Test-GetOverHere-2026.09.04_14-25-06--0700.xcresult`, 19/19 passed (`guestReconnectsAfterGuideRestartThreeTimes` 0.91 s, stalled peer 4 s, forged sender 0.12 s, 24-guest 0.2 s, `engineDefaultRoute` 0.061 ms).
5. Mutation, Kotlin reconnect test, critique-proposed `reuseAddress = true` removed (`LocalSessionControlTransport.kt:108`): `./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.LocalSessionTransportTest.guestReconnectsAfterGuideRestartThreeTimes' --continue -q`
   - Result: test still passes. `java.net.ServerSocket` enables `SO_REUSEADDR` by default on macOS/Linux, so the explicit line is documentation and this mutation cannot flip anything on the JVM. Reverted.
6. Mutation, Kotlin reconnect test, `stop()` no longer closes the listening socket (`serverSocket?.closeQuietly()` removed from `closeSockets()`): same command
   - Result: FAIL, `java.lang.IllegalStateException: Session: bind/listen failed: Address already in use` on the first `guide.startGuide()` after `guide.stop()`. Reverted; unmutated rerun 1/1.
7. Mutation, iOS reconnect test, `SO_REUSEADDR` removed from the guide listener (`LocalSessionControlTransport.swift:82-83`): the focused command of item 3 restricted to `-only-testing:GetOverHereTests/LocalSessionTransportTests` (a function-level `-only-testing` id matched no Swift Testing test and ran 0 tests, `Test-GetOverHere-2026.09.04_14-26-52--0700.xcresult`)
   - Result (staged session log of `Test-GetOverHere-2026.09.04_14-29-19--0700.xcresult`): `Test run with 17 tests in 1 suite failed after 14.515 seconds with 2 issues`; `guestReconnectsAfterGuideRestartThreeTimes` failed after 0.099 s with `LocalSessionTransportTests.swift:790: Caught error: .bindFailed("Session: bind/listen failed: Address already in use")` (the first `startGuide()` after `stop()`), and `terminalLeaveArrivesBeforeShutdown` failed the same way at `:846` because it reuses port 50_036 after the 24-guest test; the other 15 tests passed. xcodebuild then wedged in teardown with the simulator shut down (no test host process, `simctl list devices booted` empty) and was killed after five minutes (exit 143); the background wrapper's `git checkout` reverted the mutation (0 dirty lines). So the critique's mutation discriminates on iOS, where the transport sets the option itself, and does not on the JVM, where the runtime sets it.
8. Probe, `BoundedSocketFrameWriterTest` (healthy writer `sendTimeoutMillis = 50`, `healthySocket.sendBufferSize = 2_048`, a second 4 MiB frame enqueued after the tracked delivery, 300 ms sleep): `./gradlew :app:testDebugUnitTest --tests 'com.aessam.comeoverhere.BoundedSocketFrameWriterTest' --continue -q`
   - Old test (HEAD version) + probe: PASS; `Healthy writer failed` appears only in the captured stderr (the `AssertionError` died on the writer's daemon thread). New test + probe: FAIL `java.lang.AssertionError: expected null, but was:<healthy writer failed (generation=12)>`. Probe reverted; unmutated rerun 1/1.
9. Instrumented, emulator (DSCN-14), single method: `./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.AudioEngineRoutingTest#voiceCommunicationCaptureProducesAFrame -q`
   - Result: exit 0 on `GetOverHere_API_36(AVD) - 16`, `voiceCommunicationCaptureProducesAFrame` ok 0.232 s (320-byte PCM16 frame).
10. Instrumented, emulator, whole class: `./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.AudioEngineRoutingTest -q`
   - Result: exit 1; `voiceCommunicationCaptureProducesAFrame` ok 0.34 s; `listenerOutputSwitchesPhysicalCommunicationDevice` FAIL `expected:<1> but was:<2>` at `AudioEngineRoutingTest.kt:46` (the emulator exposes no `TYPE_BUILTIN_EARPIECE`, so `communicationDevice` stays the speaker). Emulator limitation per DSCN-14, not a product defect; that test is untouched by G6 and stays a physical-device check. No physical Android device was attached.
11. Deletion proofs: `rg -n 'MultipeerAudioPlane|WiFiHotspotJoiner|WiFiHotspotManager|LeaderElection|\bDataTag\b|ChannelMessage\b|NEHotspot|startLocalOnlyHotspot|HotspotConfiguration' iOS Android/app/src scripts CLAUDE.md AGENTS.md`
   - Result: only the six `RETIRED_FILES` lines and the entitlement audit line inside `scripts/verify_no_plaintext_session_paths.sh`. `touch iOS/GetOverHere/Core/MultipeerAudioPlane.swift && scripts/verify_no_plaintext_session_paths.sh` → `error: retired transport returned: .../MultipeerAudioPlane.swift`, exit 1; after removing it → `Encrypted session-path audit passed`, exit 0. `cd Android && ./gradlew assembleDebug lintDebug -q` → exit 0, `app-debug.apk` 68,257,511 bytes, lint report written.
12. Script proofs: `bash -n` over all six scripts → ok; `python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/core-parity.yml"))'` → triggers `push`, `pull_request`, `workflow_dispatch`. `env -u GOH_ANDROID_JAVA_HOME JAVA_HOME=/nonexistent scripts/verify_tour_session.sh` → prints `ANDROID_JAVA_HOME=/nonexistent`, `XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer`, then `error: Java not found under /nonexistent`, exit 1. `JAVA_HOME=/nonexistent GOH_ANDROID_JAVA_HOME= scripts/verify_core_parity.sh` → `error: Java not found under /nonexistent`, exit 1.
13. Core parity, positive: `env -u GOH_XCODE_DEVELOPER_DIR -u GOH_ANDROID_JAVA_HOME JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" scripts/verify_core_parity.sh`
   - Result: exit 0. `ANDROID_JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home`; stage 1 `Test run with 34 tests in 2 suites passed`; stage 2 `BUILD SUCCESSFUL`; stage 4 `ok fixture bytes=236`, `ok encrypted-fixture bytes=300`, `ok audio-fixture bytes=84`, `ok handshake bytes=458`, `ok realtime-fixture bytes=256`, `ok state bytes=2598`, `ok auth bytes=129`, `ok faults bytes=43`, `ok playout bytes=27`, `ok recovery bytes=110`, `ok focus bytes=85`; `Core parity passed`.
14. CI (DSCN-24): BLOCKED. The orchestration rules for this round forbid pushing, so the branch was not pushed and the workflow could not be dispatched. Exact commands to run once a push is approved: `git push -u origin fix/deep-dive-2026-09-02 && gh workflow run core-parity.yml --ref fix/deep-dive-2026-09-02 && gh run watch "$(gh run list --workflow=core-parity.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status`. `gh auth status` reports the `aessam` account logged in, so authentication is not the blocker. The first run must confirm that the `macos-latest` image ships an `Xcode_26*.app` and an `ANDROID_HOME`.
15. Gate: `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-ios-modules scripts/verify_tour_session.sh` (no `GOH_XCODE_DEVELOPER_DIR`/`GOH_ANDROID_JAVA_HOME`, so the new `xcode-select -p` / `JAVA_HOME` defaults are exercised)
   - Result: exit 0, all nine stages passed, run on the final tree (both `git rm` deletions and the entitlement edit in place, the mutations reverted). The preflight printed `ANDROID_JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home` and `XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer` from the new defaults. Stage 1: `Test run with 34 tests in 2 suites passed`. Stages 3/4/5: every byte compare, cross-decode, `faults`, `playout`, `focus`, `auth`, `recovery`, and source audit unchanged (G6 changes no core code and no wire bytes). Stage 6: `Encrypted session-path audit passed` with the new retired-file and entitlement audits. Stage 7: `lintDebug` BUILD SUCCESSFUL. Stage 8: `:app:testDebugUnitTest` 18 classes, 74 tests, 0 failures (69 before G6 plus the four new transport tests and `audioEngineDefaultsToPrivateAudio`), `app-debug.apk` 68,257,511 bytes. Stage 9: `Test-GetOverHere-2026.09.04_14-35-23--0700.xcresult` totalTestCount 82, passedTests 82, failedTests 0 (78 before G6 plus `stalledGuestDoesNotDelayHealthyGuests`, `guideDisconnectsGuestThatForgesGuideSenderID`, `guestReconnectsAfterGuideRestartThreeTimes`, `engineDefaultRoute`). The log carries one warning-only `error: the following command failed with exit code 0 but produced no further output` line on the `TourAssetCacheTests.swift` compile (the G5 main-actor initializer warnings at `:27`, `:30`, `:52`, present in the pre-G6 focused log too; not touched by G6). Final output: `Tour session verification passed`. The verifier reads no markdown file, so this ExperimentLog append after the run does not change its outcome..

Not automated, with justification: the fan-out, stalled-peer, forged-sender, and reconnect tests pass on the pre-G6 tree by construction (ADR-038/ADR-039 already hold); their value is the recorded mutations above, which show each can fail for its own claim. The `AudioEngineRoutingTest` earpiece assertion needs a physical Android device (DSCN-14). The CI workflow is unverified until the first run (item 14). The chat/file/walkie-talkie `Logger` categories in `Logging.swift` are not on the DSCN-2 list and stay.

## 2026-09-04 — Startup failure visibility (review F1) and handoff corrections (F2)

Changed only the channel-list error rendering on both platforms, added UI regressions, and corrected CLAUDE.md / NextSession.md to describe encoded PCM16-boundary audio, encrypted GOH2 v4, completed P0, and the pending P3 physical gate. No transport, credential, or lifecycle implementation changes.

Environment: macOS 27.0, selected Xcode beta, iPhone 17 Pro simulator on iOS 27.0; Android Studio JBR; attached `emulator-5554`, `GetOverHere_API_36` (Android 16).

- `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG6/verifier-ios test -only-testing:GetOverHereUITests/GetOverHereUITests/testFailedStartupShowsReasonOnChannelList`
  - Exit 0. `xcresulttool get test-results summary` for `Test-GetOverHere-2026.09.04_16-31-19--0700.xcresult`: 1 passed, 0 failed, 0 skipped. Real simulator startup failure renders a nonempty error, no live-tour picker, and an available Create action.
- From `Android/`: `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :app:assembleDebug :app:testDebugUnitTest --tests com.aessam.comeoverhere.ChannelServiceLifecycleTest`
  - Exit 0, BUILD SUCCESSFUL. Lifecycle XML: 14 tests, 0 failures, 0 errors, 0 skipped. APK assembled. Existing deprecated icon warnings remain.
- From `Android/`: `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.aessam.comeoverhere.TourNavigationTest#failedStartupShowsReasonOnChannelList`
  - Exit 0, BUILD SUCCESSFUL. 1 emulator UI test passed. A test-owned socket occupies port 50001; production startup fails to bind, rolls back, and displays the exact failure reason on the channel list. The socket closes at test exit.
- `git diff --check`: exit 0.

These tests verify failure visibility, not physical audio or RF acceptance. No hosted CI run or physical-device gate was performed. An untracked `Android/.kotlin/` directory contains an older August 21 compiler error log and was preserved.

## 2026-09-04 — Full virtual-device verification and hosted CI closeout

User authorized committing, simulator/emulator testing, and finishing pending work. Startup visibility committed as `d6f0a5a`; branch CI trigger as `38fa919`; verified wrapper as `9b02452`. Branch pushed to `origin/fix/deep-dive-2026-09-02`; main was not changed.

Environment: macOS 27.0, selected Xcode beta, iPhone 17 Pro simulator (iOS 27.0), Android Studio JBR 21, `emulator-5554` / `GetOverHere_API_36` on Android 16. Hosted runner: arm64 macOS 26, Swift 6.3.3, Temurin 21.0.12.

Failures found by the broader gates:

- Full Android `connectedDebugAndroidTest` initially failed the physical earpiece assertion (expected type 1, actual speaker type 2) and guide navigation. The emulator exposes no earpiece; the test now uses the same availability assumption as the existing focus test. Navigation asserted before asynchronous credential stretching completed; it now waits for CONNECTED. Capture teardown also stops capture explicitly.
- Full iOS `-only-testing:GetOverHereUITests` initially failed `testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration`. Its recorded accessibility tree showed the exact expected production error, `Microphone capture is unavailable in the iOS Simulator`. The live-guide test now explicitly skips Simulator and remains enabled on physical devices. The simulator startup rollback test now asserts that exact error string.
- Hosted [run 33930362544](https://github.com/aessam/GetOverHere/actions/runs/33930362544) passed 34 Swift core tests but failed because `Android/gradle/wrapper/gradle-wrapper.jar` was absent from git. `git check-ignore -v` identified the global `*.jar` rule. Regenerated with `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew wrapper --gradle-version 8.13 --distribution-type bin` from Android; the JAR SHA-256 is `81a82aaea5abcc8ff68b3dfcb58b3c3c429378efd98e7433460610fecd7ae45f`, matching `https://services.gradle.org/distributions/gradle-8.13-wrapper.jar.sha256`. Added a repository ignore exception and committed the generated wrapper. [Run 33930529033](https://github.com/aessam/GetOverHere/actions/runs/33930529033) on `9b02452` passed. Its deprecated-action warnings prompted selecting official `actions/checkout@v7.0.1` and `actions/setup-java@v6.0.0`; both declare Node 24, verified from their tagged `action.yml` files.

Final local command (exit 0):

```bash
GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-ios-modules scripts/verify_virtual_devices.sh
```

Results, captured in `/tmp/GetOverHere-final-virtual-gate.log`:

- Host gate: `Tour session verification passed`; 34 Swift core tests, Swift/Kotlin byte comparisons and cross-decodes, churn/fault/recovery/privacy audits, Android lint/APK, 74 Android JVM tests, 82 iOS unit/integration tests. Gradle reused unchanged successful JVM outputs on the final combined run; the earlier full gate executed the suite.
- iOS UI: `Test-GetOverHere-2026.09.04_16-45-14--0700.xcresult`, summary `Passed`, 3 test methods passed (6 runs across configurations), 1 physical-guide method skipped, 0 failed.
- Android instrumentation: XML contains 16 test cases, 14 passed, 2 earpiece checks skipped, 0 failures/errors. Includes native Opus/AAC encode/decode, encrypted realtime transport, audio-lane reconnect, audio focus, local PMTiles rendering, startup-error UI, Slides/Map/Pointer navigation, and Activity recreation. Gradle's console says `Finished 18 tests`; totals above come from the testcase XML, not that console counter.
- Final output: `Virtual-device verification passed; physical audio and radio gates remain separate`.
- `bash -n scripts/verify_virtual_devices.sh` and `git diff --check` passed. Negative preflight with `ANDROID_SERIAL=physical-device` reports `select an emulator with ANDROID_SERIAL; physical gates run separately` before starting any tests.

Remaining: physical guide capture/UI, earpiece routing, both cross-platform guide directions, sustained LAN audio/latency/background/thermal/battery acceptance, followed by the physical Aware gate and its dependent production/BLE work. Virtual-device results do not satisfy those gates.

## 2026-09-04 — Physical-device readiness and native checks; LAN session paused for admission redesign

Source: `5420da7`. Devices: Dark knight / iPhone 17 Pro Max, iOS 27.0 build 24A5430a, UDID `00008150-001208901AC0401C`; Pixel 11 Pro, Android API 37, serial `66180DLKX006ND`. The Pixel had a LAN address on wlan0. Both devices were unlocked and available.

- `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'id=00008150-001208901AC0401C' -derivedDataPath /tmp/GetOverHerePhysicalBaseline -allowProvisioningUpdates build`: exit 0. Signed build installed with `xcrun devicectl device install app --device F043EBB9-780F-5483-B0D1-BC0BD9955D9C /tmp/GetOverHerePhysicalBaseline/Build/Products/Debug-iphoneos/GetOverHere.app`.
- `ANDROID_SERIAL=66180DLKX006ND JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew connectedDebugAndroidTest` from Android: exit 0; XML `TEST-Pixel 11 Pro - 17-_app-.xml` has 16 tests, 0 failures/errors/skips. Physical earpiece switching and focus routing passed, as did native codecs, encrypted realtime loopback, map rendering, navigation, startup rollback, and lifecycle. This is single-device test evidence, not cross-platform audio evidence.
- `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'id=00008150-001208901AC0401C' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHerePhysicalBaseline -allowProvisioningUpdates test -only-testing:GetOverHereTests/NativeRealtimeAudioCodecTests -only-testing:GetOverHereTests/NativeAudioCodecCapabilitiesTests -only-testing:GetOverHereUITests/GetOverHereUITests/testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration`: exit 0. `Test-GetOverHere-2026.09.04_17-21-28--0700.xcresult`: 4 test methods passed (5 parameterized runs), 0 failures/skips. Native Opus and AAC-LC and the actual guide UI passed. Runtime warning: synchronous AVAudioSession activation/deactivation on the main thread can cause UI unresponsiveness. Xcode's auxiliary devicectl diagnostics collection was partial; the test result itself passed.
- Android instrumented cleanup left the app absent (`am start` returned Activity error type 3); reinstalled the verified APK with `adb -s 66180DLKX006ND install -r Android/app/build/outputs/apk/debug/app-debug.apk`, then launched `com.aessam.comeoverhere/.MainActivity`, both successfully.
- `scripts/capture_physical_test.sh start --ios-device F043EBB9-780F-5483-B0D1-BC0BD9955D9C --android-serial 66180DLKX006ND`: first run `/tmp/GetOverHerePhysicalRuns/20260905T002239Z-39529` collectors exited after launcher return. Repeated under a persistent supervisor (`&& tail -f /dev/null`), run `/tmp/GetOverHerePhysicalRuns/20260905T002342Z-39748`. User requested open-by-default rooms with optional code locking before a cross-platform listening result was received. Marked that run `Physical LAN baseline paused for open-room admission change`, stopped capture through the script, and terminated the idle supervisor.

No claim of two-phone audio, 30-minute endurance, or physical Aware success. Those gates remain pending. The next product change is open admission by default with the guide's explicit `Lock Room with Code` action; behavior for already-admitted guests is being clarified before changing the credential contract.

## 2026-09-04 — Open rooms with editable code locking (ADR-052)

Implemented on branch `fix/deep-dive-2026-09-02`: open-by-default rooms, guide toggle and code editor, discovery lock status, separate authenticated admission on TCP 50003, unchanged GOH4 media credentials for existing guests. Codes are case-sensitive, 4–64 printable ASCII characters without spaces. CLI parity exercises real ephemeral P-256 exchanges rather than deterministic test keys.

- `GOH_SWIFT_SCRATCH=/tmp/GetOverHereRoomAdmission scripts/verify_core_parity.sh`: passed core tests, existing eleven byte-exact fixtures, and eight real Swift/Kotlin admission exchanges (both directions; open, four-character, mixed-character, and maximum-length codes). Logs: `/tmp/GetOverHere-room-parity.log`, final rerun `/tmp/GetOverHere-room-final-parity.log`.
- `GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-ios-modules scripts/verify_virtual_devices.sh`: final complete pass, `/tmp/GetOverHere-room-final-virtual.log`. Includes source/privacy audit, JVM tests (77, zero failures from JUnit XML), lint, APK, iOS unit/integration and UI suites, emulator instrumentation. Emulator XML remains 16 cases: 14 pass and two hardware-earpiece skips; Gradle prints 18 because it counts skipped callbacks twice.
- `xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'id=00008150-001208901AC0401C' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHerePhysicalBaseline -allowProvisioningUpdates test -only-testing:GetOverHereTests/RoomAdmissionTransportTests -only-testing:GetOverHereUITests/GetOverHereUITests/testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration`: iPhone 17 Pro Max / iOS 27, two tests passed, zero failures/skips. Result `Test-GetOverHere-2026.09.04_17-51-04--0700.xcresult`; log `/tmp/GetOverHere-room-physical-ios.log`. Actual loopback tests lock/edit/unlock and preserve the session secret; UI tests edit the field and toggle the switch. Retained screenshot exported to `/tmp/GetOverHere-room-ios-passed/A026D00F-5E75-466F-ACC0-8F020DD414B9.png`, visually inspected.
- `ANDROID_SERIAL=66180DLKX006ND JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' Android/gradlew -p Android connectedDebugAndroidTest`: Pixel 11 Pro / API 37, final 16 tests passed without skips; `/tmp/GetOverHere-room-physical-android.log`.
- Initial failures corrected: misplaced Kotlin import and explicit Swift closure capture syntax; privacy audit rejected raw exceptions in new Android logs; iPhone XCTest tapped the outer SwiftUI toggle container instead of its inner switch; Pixel UI test assumed an empty nearby-room list after ending the local tour. The latter now asserts local session termination and Create availability, which remains valid around other guides. No product behavior was weakened to pass these checks.

Live follow-up: reinstalled and launched the verified Pixel app after instrumentation. Pixel discovered an open room. At 17:58:34 and 17:58:38 its production log reports `TCP: authenticated GOH2 session joined` then `TCP: received first GOH2 audio frame`, followed by `native audio decode failed (IllegalStateException)`. AndroidRuntime shows an uncaught `MediaCodec.stop()` failure during receive-thread cleanup. Thus physical admission/first-frame reception is observed, but sustained two-phone audio is NOT passing. This pre-existing codec interoperability/cleanup defect is the next separate fix; no 30-minute audio or Aware acceptance is claimed. Stopped UI automation on physical phones when their state changed during manual testing.

## 2026-09-04 — Fix Apple→Android codec initialization, PCM rate, and cleanup crash (ADR-053)

Environment: same M4 Max/Xcode beta toolchain, Android Studio JBR, API 36 emulator `emulator-5554`, and physical Pixel 11 Pro/API 37 `66180DLKX006ND`. No production Swift or wire-format changes.

Reproduction and correction:

- New `PlayoutClockTest.decoderCleanupFailureDoesNotEscapeReceiveThread` failed before the fix with `IllegalStateException` from decoder close (`/tmp/GetOverHere-codec-cleanup-repro.log`). After idempotent, contained cleanup it passes and asserts one failure notification and one decoder close across two close calls.
- Production Apple-encoded tone packets reproduced Android native failure (`/tmp/GetOverHere-codec-interop-repro.log`). Removing `stop()` exposed the underlying `dequeueOutputBuffer` error without the masking cleanup exception (`/tmp/GetOverHere-codec-interop-cleanup-fixed.log`). Documented Android codec initialization resolved it.
- The physical duration assertion then failed: Opus returned 61,440 PCM bytes for approximately 20,480 expected (`/tmp/GetOverHere-codec-pixel.log`). Actual 48 kHz output now passes through a streaming anti-aliased 48→16 kHz converter. The converter's initial frequency test counted startup transients; measurement now excludes the first 64 output samples and still checks frequency, amplitude, alias rejection, and exact chunked/whole-output equality.
- `GOH_SWIFT_SCRATCH=/tmp/GetOverHereRoomAdmission scripts/generate_native_codec_fixture.sh > /tmp/GetOverHere-apple-codec-regenerated.hex 2>/tmp/GetOverHere-codec-generate.log`: generated 63 real encoded packets. Retained asset uses 32 Opus and 31 AAC-LC packets from the production Apple encoder, with generated 440 Hz input. A comparison against a later regeneration differed in AAC output; byte-identical native encoding across runs is not a gate. Tests use the fixed retained capture.

Final verification:

```bash
GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-ios-modules scripts/verify_virtual_devices.sh
ANDROID_SERIAL=66180DLKX006ND scripts/verify_native_codec_interop.sh
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' Android/gradlew -p Android testDebugUnitTest
```

- Complete virtual-device gate passed (`/tmp/GetOverHere-codec-final-virtual.log`): host core/wire/privacy checks, lint/APK, iOS unit/integration and UI suites, and Android emulator instrumentation. Hardware-earpiece checks explicitly skip; no emulator failure.
- Focused physical gate passed, five native-codec instrumented tests (`/tmp/GetOverHere-codec-final-pixel.log`). Includes actual Apple Opus/AAC decoding with duration, non-silence, and tone-frequency assertions, plus Apple-packet replay through encrypted realtime transport. Cleanup/converter JVM regressions pass through the same reusable script.
- Complete JVM suite: 81 tests, zero failures/errors from `Android/app/build/test-results/testDebugUnitTest/TEST-*.xml`; `/tmp/GetOverHere-codec-final-unit.log` ends `BUILD SUCCESSFUL`.
- Full physical-suite follow-up (`ANDROID_SERIAL=66180DLKX006ND JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' Android/gradlew -p Android connectedDebugAndroidTest`) was interrupted after ten completed tests, not counted as a passing full suite. Gradle reported process crash during the eleventh test. Its captured log shows `adbd service requested 'shell:am force-stop com.aessam.comeoverhere'` at 20:11:52.445; this session issued no force-stop. No new application exception appears in the crash buffer. Artifact: `/tmp/GetOverHere-codec-final-pixel-full.log` and the instrumented Apple-transport testcase log under `Android/app/build/outputs/androidTest-results/connected/debug/Pixel 11 Pro - 17/`.
- Read-only follow-up found the production app in the live Bolbol room, LISTENING, displaying a guide-selected pointer. PID 25858 logged 16 kHz playback at 20:12:16, authenticated audio at 20:12:17.231, first frame at 20:12:17.263, and remained alive through 20:13:36 without the prior decode/cleanup exception in the inspected interval. One startup short write (64/640 bytes, count 1) was logged; do not infer loss-free playback. Later rolling-log excerpt saved to `/tmp/GetOverHere-codec-live-pixel.log`. The app was already running the fixed build; no reinstall or UI automation interrupted that live session.
- `bash -n scripts/generate_native_codec_fixture.sh scripts/verify_native_codec_interop.sh` and `git diff --check` passed.

The reproduced initialization/cleanup crash is fixed. These results do not establish audible quality, sustained two-phone endurance, reverse-direction acceptance, or Aware/BLE readiness. No raw microphone recording or physical-device log is committed.

## 2026-09-04 — Stable LAN tag and Bluetooth discovery slice (ADR-054)

The user approved the first discovery slice and requested a stable checkpoint. The tree was clean at `59b0402c91cfabb3eb839800b2b8521be90854e0`; no empty commit was created. `git tag -a stable-local-network 59b0402c91cfabb3eb839800b2b8521be90854e0 -m 'Stable Local Network'` created the requested annotated local tag. It remains on the LAN/audio-fix baseline and was not pushed or moved to the Bluetooth work.

Affected ownership: new `BluetoothRoomRecord` in each shared core; new `BluetoothRoomDiscovery` and `RoomDiscoveryIndex` in each app's Core; `LocalControlPlane` owns both discovery sources; `ChannelService` protects existing sessions against address-less observations; both room-list UIs distinguish discovery-only rooms; platform permission declarations and Android's permission prompt enable the radio. `NetworkCoordinator` still constructs `LocalControlPlane`; no other discovery call site selects the legacy BLE command channel. No admission/audio transport contract changed.

Software commands:

```bash
GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios scripts/verify_bluetooth_discovery.sh
GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift GOH_SWIFT_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-swift-modules GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios GOH_IOS_MODULE_CACHE=/tmp/GetOverHereFixG6/verifier-ios-modules scripts/verify_virtual_devices.sh
xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'generic/platform=iOS' -derivedDataPath /tmp/GetOverHerePhysicalBaseline -allowProvisioningUpdates build
```

- Focused discovery gate passed (`/tmp/GetOverHere-bluetooth-gate.log`). Early compilation failures corrected: Kotlin `isEmpty` needed a call; Swift Testing's `#require` cannot capture a mutating struct receiver, so mutations are evaluated before assertions. These were compile failures, not physical-radio failures.
- Full virtual gate passed twice (`/tmp/GetOverHere-bluetooth-full-virtual.log`, `/tmp/GetOverHere-bluetooth-final-virtual.log`), including host core/wire/source/privacy checks, Android lint/APK, full iOS unit/integration and UI suites, and emulator instrumentation.
- Final full-run counts: 39 Swift core tests; 85 Android app JVM tests, zero failures/errors from JUnit XML; iOS unit/integration result `Test-GetOverHere-2026.09.04_20-49-28--0700.xcresult` reports 90 passing methods (92 parameterized runs), zero failures/skips. UI result `Test-GetOverHere-2026.09.04_20-50-36--0700.xcresult` reports three passing methods (six runs), one physical-guide skip, zero failures. Android emulator XML has 20 cases, 18 pass, two hardware-earpiece skips, zero failures/errors; Gradle's console double-counts skipped callbacks and prints 22.
- New coverage: identical Swift/Kotlin GOR1 hex fixture, 100 Unicode roundtrips per platform and maximum-length input, malformed/truncated records, LAN preference, source-loss fallback/deduplication, unresolved-LAN filtering, production Bluetooth observation forwarding, active-session preservation, and an actual Compose UI assertion that a Bluetooth-only room is visible but cannot invoke Join until a LAN address resolves.
- Signed iPhone build passed (`/tmp/GetOverHere-bluetooth-physical-build.log`, later `/tmp/GetOverHere-bluetooth-final-signed-build.log`). Xcode printed existing dependency-scan/actor warnings despite exit 0; no physical installation or radio success is inferred from the build.
- Final review added explicit removal of cached advertised metadata in both radios' `stop()`, preventing an ended room from reappearing on a later start. The focused software gate passed again after this two-line lifecycle correction; artifact `/tmp/GetOverHere-bluetooth-final-focused.log`.
- `bash -n scripts/verify_bluetooth_discovery.sh` and `git diff --check` passed.
- Installed the final APK on `emulator-5554`, observed and accepted the actual Nearby devices permission prompt, and visually inspected the room-list screenshot `/tmp/GetOverHere-bluetooth-emulator-ready.png`. The Bluetooth/access explanation wraps without clipping; the Create action remains visible. Logcat reports `Bluetooth room discovery scanning`. This is emulator startup/UI evidence, not radio interoperability.

Physical attempt and blockers:

```bash
xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'id=00008150-001208901AC0401C' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHerePhysicalBaseline -allowProvisioningUpdates test -only-testing:GetOverHereUITests/GetOverHereUITests/testGuideCanReachSlidesMapAndPointerWithoutLegacyConfiguration
xcrun devicectl --timeout 10 device info lockState --device F043EBB9-780F-5483-B0D1-BC0BD9955D9C
/Users/aessam/Library/Android/sdk/platform-tools/adb devices -l
```

The Pixel is absent from adb; only `emulator-5554` remains. Xcode reports `Unlock Dark knight to Continue`; the documented lock-state command confirms `passcodeRequired: true`. The waiting device test (`/tmp/GetOverHere-bluetooth-iphone-ui.log`, this session's PID 89881) was cancelled with SIGTERM after confirming its exact command, so it cannot unexpectedly take over the phone later. The user was asked to reconnect the Pixel and unlock the iPhone. No lock bypass or radio-setting change was attempted.

Physical gate still required: with Wi-Fi off and Bluetooth on, create a real guide room and verify the other phone displays its name/lock status as discovery-only; change lock status, end/recreate the room, test expiration and Bluetooth off/on, and reverse guide/guest roles. Then restore LAN and verify one merged room with joining enabled. Foreground discovery is the current slice; Bluetooth admission, control, voice, background endurance, and group scale are not delivered by this checkpoint.

## 2026-09-05 — A1 review remediation and A2 physical preflight

Starting commit: `7a41610`. The user approved A1–A5 continuous execution with physical/security gates. Changes: explicit opt-in foreground Bluetooth discovery, browser/guide role separation, scan duty reduction, nonblocking admission completion, reverse native-codec fixtures, deterministic leading-zero ECDH coverage, admission in the main gate, and current onboarding/security documentation (ADR-055). No production reverse-codec change was needed. No BLE admission/control/voice or Aware production capability is claimed.

Environment: selected Xcode beta / iOS 27 SDK; simulator iPhone 17 Pro `A7202CAB-B085-4F1A-A7B5-8AE00A839E76`, runtime 26.4.1 (23E254a); Android `emulator-5554`, API 36 / Android 16; Android Studio JBR; macOS 27. Physical Pixel remained absent and Dark knight required its passcode.

Executed gates:

```bash
# Initial Android compilation, JVM tests and lint: PASS.
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' Android/gradlew -p Android :tour-session-core:test :app:testDebugUnitTest :app:assembleDebug :app:lintDebug

# Deterministic shared-secret edge: PASS; same derived key in Swift/Kotlin for scalars 1 and 379.
swift test --disable-sandbox --package-path Packages/TourSessionCore --scratch-path /tmp/GetOverHereFixG6/verifier-swift --filter RoomAdmissionTests

# Focused iOS lifecycle / full-socket / lock-edit-unlock: PASS, 23 test methods.
xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,id=A7202CAB-B085-4F1A-A7B5-8AE00A839E76' -parallel-testing-enabled NO -derivedDataPath /tmp/GetOverHereFixG6/verifier-ios test -only-testing:GetOverHereTests/RoomAdmissionTransportTests -only-testing:GetOverHereTests/ChannelServiceLifecycleTests

# Complete final virtual gate: PASS.
GOH_IOS_DESTINATION='platform=iOS Simulator,id=A7202CAB-B085-4F1A-A7B5-8AE00A839E76' GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios GOH_SWIFT_SCRATCH=/tmp/GetOverHereFixG6/verifier-swift bash scripts/verify_virtual_devices.sh

# Fresh Android production encoder -> production iOS decoder: PASS.
GOH_IOS_DESTINATION='platform=iOS Simulator,id=A7202CAB-B085-4F1A-A7B5-8AE00A839E76' GOH_IOS_DERIVED_DATA=/tmp/GetOverHereFixG6/verifier-ios bash scripts/verify_reverse_codec_interop.sh

git diff --check
bash -n scripts/verify_reverse_codec_interop.sh scripts/verify_tour_session.sh scripts/verify_virtual_devices.sh scripts/verify_bluetooth_discovery.sh
```

Final full-gate log: `/tmp/GetOverHere-A1-final-virtual.log`, ending `Virtual-device verification passed; physical audio and radio gates remain separate`. Swift core: 40 methods; real admission parity: 8/8 exchanges; Android JVM XML: 88 tests. Xcode summary for `Test-GetOverHere-2026.09.05_19-59-10--0700.xcresult`: 94 iOS unit methods / 97 parameterized runs, zero failures. UI bundle `Test-GetOverHere-2026.09.05_20-00-04--0700.xcresult`: four passing methods / seven runs plus one physical-guide skip. Android instrumentation XML contains 24 test cases, zero failures/errors and two earpiece skips; its progress console also printed 26 completions, so the XML is used for the case count. `RoomAdmissionBoundaryTest` passed the Android-provider leading-zero and actual NIO lock/edit/unlock cases.

Reverse-codec log: `/tmp/GetOverHere-A1-final-reverse.log`, ending `Android-to-iOS native codec gate passed`. Retained input: `iOS/GetOverHereTests/android-native-codec.hex`, 128 generated-tone packets from production Android encoders. Tests assert approximately one negotiated frame duration per packet (two-frame priming allowance), RMS above 1,000 and 440 Hz within 10 Hz. The fresh gate injects its exported file path via a generated `.xctestrun` environment; normal unit tests use the bundled fixture. No recorded speech or microphone data is retained.

Failed attempts and corrections:

- The first reverse harness used Gradle connected tests followed by `run-as`; Gradle had uninstalled the package and the captured text was `run-as: unknown package`. Changed to explicit install/instrument/read and strict hex validation. An initial iOS 27 simulator startup did not reach tests and was cancelled; the recorded passing run uses 26.4.1 with parallel cloning disabled.
- The first Android guide lifecycle assertion checked before its asynchronous collector applied the mode. The test now drives its scheduler and waits for the observable state. Production lifecycle behavior was not weakened to satisfy the test.
- `/tmp/GetOverHere-A1-full-virtual.log` was cancelled during the new iOS full-socket regression. `sample 77734 1 -file /tmp/GetOverHere-A1-ios-sample.txt` placed the blocked thread inside the fixture's `send(..., MSG_DONTWAIT)`. Replaced per-send assumptions with verified `O_NONBLOCK` preparation before the policy lock. The focused full-socket regression then passed in 0.006 s; full verification subsequently passed. Android similarly prepares a nonblocking channel before its locked send. No blocking reply retries remain under either policy lock.
- Added unique UI identifiers for room locking and discovery; the old Android `isToggleable()` selector became ambiguous with two switches.

Visual verification: exported and inspected the iOS launch attachment at `/tmp/GetOverHere-A1-ui-attachments/5EE445B1-478B-4F23-8787-967C84C1F9FF.png`; inspected `/tmp/GetOverHere-A1-android-ui.png`. Both display discovery off and the foreground-preview/LAN-audio limitation without clipping. Android package inspection showed SCAN, CONNECT and ADVERTISE all `granted=false` at launch with no permission dialog. Tapping the explicit switch produced the system Nearby devices prompt (`/tmp/GetOverHere-A1-permission.xml`). These are emulator/UI observations, not physical BLE evidence.

Physical preflight:

```bash
/Users/aessam/Library/Android/sdk/platform-tools/adb devices -l
xcrun devicectl device info lockState --device F043EBB9-780F-5483-B0D1-BC0BD9955D9C
bash scripts/capture_physical_test.sh start --ios-device F043EBB9-780F-5483-B0D1-BC0BD9955D9C --android-serial 66180DLKX006ND --run-dir /tmp/GetOverHerePhysicalRuns/A2-2026-09-05
```

Result: only `emulator-5554` in adb; iPhone `passcodeRequired: true`; capture harness exits 1 with `error: Android device 66180DLKX006ND is unavailable` (`/tmp/GetOverHere-A2-preflight.log`). A2 is blocked, not passed. The user was asked to reconnect/authorize Pixel and unlock iPhone. A3–A5 remain pending behind the physical gates and guide-key bootstrap decision. The `stable-local-network` tag still resolves to `59b0402c91cfabb3eb839800b2b8521be90854e0`; no tag promotion or push was performed.

Final permission-denial UI check: after installation completed, launched `com.aessam.comeoverhere/.MainActivity`, tapped the discovery switch at emulator coordinates `(970,294)`, inspected the permission dialog with `adb shell uiautomator dump`, then tapped its deny button at `(540,1480)`. `/tmp/GetOverHere-A1-denied-final.xml` contains the app UI, `checked="false"`, and `Bluetooth permission denied. Enable it in Settings to try again.` An earlier probe overlapped APK reinstallation and was discarded; it is not used as denial or crash evidence. No physical phone settings were changed.

## 2026-09-06 — Direct nearby implementation and physical fault isolation (ADR-056)

Environment: branch `fix/deep-dive-2026-09-02`, baseline `492572e`; Xcode beta at `/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer`, iPhone 17 Pro simulator `A7202CAB-B085-4F1A-A7B5-8AE00A839E76`; Android Studio JBR; Pixel 11 Pro `66180DLKX006ND`, Pixel 7 `2A111FDH2007A1`, both reporting API 37. Physical evidence files remain under `/tmp`, outside the repository, because logcat can contain unrelated private data.

Commands (roles reversed by swapping the two serial variables):

```bash
GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh
GOH_NEARBY_TRANSPORT=aware GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh
GOH_NEARBY_WIFI_OFF=1 GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh
```

Each fixture uses real native radio connections, production locked admission (`2468`, test-only), hidden test media credential, native encoded audio, authenticated control and assets. Guide generates a 440 Hz PCM16 tone at 16 kHz and sends pointer/512-byte deterministic asset state every second. Guest must receive exact asset bytes and at least 100 non-silent native decoded callbacks. This is not microphone/playback, acoustic, locked-screen, endurance, or group testing.

| Attempt | Evidence directory/log | Observed result |
|---|---|---|
| BLE initial | `/tmp/GetOverHereNearbyPhysical.5INHpI` | Admission/audio authentication and first frame, but pointer timeout. One of three concurrent L2CAP opens failed. |
| BLE serialized opens | `/tmp/GetOverHereNearbyPhysical.nKu234` | Control and assets arrived; non-silent audio threshold failed. Retained as a real failure. |
| BLE forward | `/tmp/GetOverHereNearbyPhysical.VwpZoD` | Both roles passed; guest 13.582 s. |
| BLE reverse | `/tmp/GetOverHereNearbyPhysical.xK86PG` | Both roles passed; guest 17.413 s. |
| Aware initial | `/tmp/GetOverHereNearbyPhysical.oddqdI` | Pixel 7 explicitly reported no native pairing support. No data-path pass. |
| Aware secure legacy NAN | `/tmp/GetOverHereNearbyPhysical.Jctcxq` | Data-path timeout, not a pass. |
| Aware advertised security/responder-first | `/tmp/GetOverHereNearbyPhysical.OmzMYO` | Both roles passed; guest 15.016 s. |
| Aware reverse | `/tmp/GetOverHereNearbyPhysical.qgrHEB` | Both roles passed; guest 16.306 s. |
| BLE repeated forward/reverse | `/tmp/GetOverHere-nearby-ble-repeat.log`, `/tmp/GetOverHereNearbyPhysical.dS6iUw` | Both directions passed; reverse guest 13.661 s. |
| Wi-Fi disabled, before hop ACKs | `/tmp/GetOverHereNearbyPhysical.lAN8Wh` | Control/assets arrived; only 25/100 non-silent audio callbacks. Receiver logged frame 300 as EXPIRED. Wi-Fi restored to enabled on both phones. |
| Wi-Fi disabled, four-frame ACK window | `/tmp/GetOverHereNearbyPhysical.go3KXD` | Both roles passed; guest 13.473 s. Both phones were verified disabled before instrumentation and restoration requested afterward. |

The Wi-Fi-off failure isolated an unbounded native in-flight backlog beyond the application queue. `NearbyRealtimeConnection` now permits four unacknowledged framed records per native direction, strips zero-length hop ACKs before the application stream, serializes ACK/data writes, and closes a peer after one second without ACK. Swift and JVM tests check a blocked fifth frame, 500 exact bidirectional roundtrips, and missing-ACK closure. The first Kotlin timeout regression caught an accidental call to `OutputStream.close()` rather than the owning connection; explicit owner qualification fixed it, and all three focused JVM tests then passed (`/tmp/GetOverHere-nearby-ack-tests-2.log`). iOS focused ACK suite also passed (`/tmp/GetOverHere-nearby-ack-ios-tests.log`).

The broad gate initially rejected new raw exception logging, then a missing API-29 guard inside the deferred Bluetooth connector. Both were corrected instead of suppressing the gates. Focused iOS integration runs passed, including failed-nearby-admission cleanup and three-source fallback. The real-device iOS target, including the opt-in mixed-platform physical fixture, compiled with signing disabled (`/tmp/GetOverHere-nearby-device-build-3.log`, exit 0); that is compiler evidence, not an installed iPhone result. `devicectl device info lockState` failed with CoreDevice 4000/control-channel reset on the iPhone, so no iPhone RF pass is claimed.

Mixed-platform Aware remains incomplete: Android uses PIN-secured NDP, whereas Apple owns system-paired link security. The production UI and current docs state this. The direct implementation does not contain signed relaying or guide-key pinning. `stable-local-network` remains at `59b0402`.

Wi-Fi-off reverse follow-up: `/tmp/GetOverHereNearbyPhysical.AKejZL` passed both roles, guest 13.660 s. The preceding reverse command stopped at an optional Aware display-name nullability compile error before changing any radio state; the nullable field was handled and the run repeated. `/tmp/GetOverHere-nearby-wifi-off-ack-reverse-2.log` contains the disabled-state checks, results and restore requests. Final `adb -s <serial> shell settings get global wifi_on` returned `1` on both phones. No Wi-Fi setting was left changed.

Virtual-device follow-up: `verify_virtual_devices.sh` initially passed all nine host gates and iOS UI tests, then found a clipped pointer privacy label in Android's guide screen. Its failed navigation test left an application-owned tour running, causing the next deliberate bind-failure fixture to collide with that listener. Collapse nearby settings during an active tour, make pointer content scrollable, and release the tour in test teardown even after an assertion. The focused `TourNavigationTest` rerun passed 3/3 (`/tmp/GetOverHere-nearby-navigation-retest.log`). This preserves the intended application-owned runtime across Activity recreation instead of stopping production tours when a screen closes.

Subsequent complete virtual run passed (`/tmp/GetOverHere-nearby-virtual-final-2.log`): all nine host gates; iOS unit/integration 102 passed, one physical-only skip; iOS UI suite passed; Android emulator XML reports 25 tests, zero failures/errors, three hardware-only skips. Fresh Android-encoded packets decoded by production iOS simulator code passed (`/tmp/GetOverHere-nearby-reverse-codec-final.log`). These results precede the availability tracker and diagnostic-message follow-ups below.

Late Aware discovery attempts `/tmp/GetOverHereNearbyPhysical.W26iaa` and `.k1nYkz` failed before admission. Sleeping displays were observed; no single root cause was isolated. Duplicate availability broadcasts now leave ownership unchanged, real availability transitions retain the pairing PIN, the physical fixture owns a foreground Activity, and the script wakes displays without bypassing a keyguard. Optional display-name service data was removed. The next run `/tmp/GetOverHereNearbyPhysical.dZ91ed` passed both roles (guest 14.359 s). Because multiple changes preceded that pass, it does not isolate which change restored discovery; no current reverse rerun occurred before phones became unavailable.

The signed iOS build passed (`/tmp/GetOverHere-nearby-signed-build.log`) and installation succeeded (`/tmp/GetOverHere-nearby-ios-install.log`), superseding the earlier CoreDevice connection failure. No physical iOS radio fixture completed. User then reported `Network.NWError -11992 WiFi Aware` and requested simulator/emulator work only while travelling. No further phone operations are authorized for this interval. `codesign -d --entitlements - /tmp/GetOverHereNearbySigned/Build/Products/Debug-iphoneos/GetOverHere.app` confirms Publish and Subscribe in the signed app. Apple public documentation does not establish a cause for this numeric error; do not label it a permissions, pairing, or OS defect without device evidence. Added operation/code-preserving error messages and mixed-platform limitations beside Apple's pairing controls. This is diagnostic/UX remediation, not a claimed native radio fix.

Final virtual-only command:

```bash
GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer GOH_IOS_DERIVED_DATA=/tmp/GetOverHereNearbyIOS GOH_IOS_DESTINATION='platform=iOS Simulator,id=A7202CAB-B085-4F1A-A7B5-8AE00A839E76' ANDROID_SERIAL=emulator-5554 bash scripts/verify_virtual_devices.sh
```

The first attempt caught missing iOS-26 availability annotations in the new native-error regression; fixed with an availability check and test annotation. Rerun `/tmp/GetOverHere-nearby-virtual-no-phones-2.log` exited 0: all nine host gates, 44 Swift core tests, eight real cross-language admission exchanges, Android lint, 98 JVM tests with zero failures/skips, iOS unit/integration 104 passed and one physical-only skip, iOS UI four distinct tests passed and one physical-only skip (seven parameterized executions passed), Android emulator XML 25 tests with zero failures/errors and three hardware-only skips. `xcresulttool get test-results summary` read the 20-33-45 and 20-34-25 simulator bundles; Ruby/REXML summed the JVM and connected-debug XML attributes. Existing Swift concurrency warnings remain in older asset-cache tests; the gate is not warning-free. No physical phones were contacted. Both new physical scripts pass `bash -n`; the Android script now captures only this app's PID, never unrelated apps' logcat. `git diff --cached --check` passed.

## 2026-09-06 — Aware owner recovery after the native failure report

Baseline `8c73fa9`. Read-only review found that iOS owner failure left mode, probes and cached endpoints alive, and same-mode restart was ignored. Fatal Android attach/configuration/startup errors similarly did not release their owner. Added teardown before reporting fatal errors, while retaining per-peer error handling and ignoring cancellation from replaced iOS operations. Native operation/capability injection in iOS tests is a boundary double; it does not simulate RF or claim native interoperability.

Focused command: `DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,id=A7202CAB-B085-4F1A-A7B5-8AE00A839E76' -derivedDataPath /tmp/GetOverHereNearbyIOS -parallel-testing-enabled NO test -only-testing:GetOverHereTests/WiFiAwareLifecycleTests`. First compile rejected a suite-level minor-version availability annotation (`/tmp/GetOverHere-aware-lifecycle.log`); replaced it with enabled traits and runtime availability guards. Three initial focused cases passed (`/tmp/GetOverHere-aware-lifecycle-2.log`), then added unexpected-native-cancellation and capability-recheck cases.

Repeated the full virtual-only command above, output `/tmp/GetOverHere-aware-recovery-virtual.log`, exit 0. All nine host gates, iOS UI and Android emulator instrumentation passed. The 21-02-32 simulator result summary reports 109 passed, zero failed, one hardware-only skip, including all five lifecycle cases. Android instrumentation finished with zero failures and three hardware-only skips. Final line: `Virtual-device verification passed; physical audio and radio gates remain separate`. Native `-11992`, mixed-platform Aware security and signed relay remain unresolved; no phone operations occurred.

Public-contract investigation: [Apple service naming](https://developer.apple.com/documentation/wifiaware/waservice/name) confirms the full over-air service name, so no speculative bundle-ID prefix was added. [Android link security](https://developer.android.com/reference/android/net/wifi/aware/WifiAwareDataPathSecurityConfig.Builder) requires concrete key material for its configured cipher; no Apple-paired key derivation was invented. [Apple DTS interoperability guidance](https://developer.apple.com/forums/thread/790195) points to accessory compatibility requirements and vendor investigation; it does not establish a fix for this app or the reported error. No private APIs, rooted-device workarounds, SDK-floor changes or downgrade of application authentication were introduced.

## 2026-09-07 — Signed-guide core prerequisite (ADR-057)

Baseline `9f47662`; same Xcode beta/JBR, Android API-36 emulator only. No physical phone operations. New ownership: Swift/Kotlin session cores implement immutable GOS1 signing/verification; both CLIs expose test signing/verification; scripts run real cross-language exchanges; an Android instrumentation test exercises the native security provider. No app admission or transport call site uses the wrapper yet, and no relay capability is enabled.

`bash scripts/verify_core_parity.sh` initially found a Kotlin ByteArray `ifEmpty` API mismatch (`/tmp/GetOverHere-guide-signature-core.log`); explicit empty-array handling fixed it. The corrected core gate passed, then canonical low-S enforcement and clean CLI rejection were added. Final core gate `/tmp/GetOverHere-guide-signature-canonical.log` passed: 46 Swift tests, 48 Kotlin tests, existing wire fixtures, eight real admission exchanges, and eight fresh signatures in each language direction. DER/raw tests include 1,000 fixed-seed leading-zero samples and high-bit/zero boundaries. Each signed fixture rejects every single-byte mutation, every truncation, trailing data, wrong keys/identities, and equivalent high-S encoding.

Extended command: `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' python3 scripts/verify_guide_signatures.py /tmp/GetOverHereCoreParitySwift/out/Products/Debug/tour-session-swift Android/tour-session-cli/build/install/tour-session-cli/bin/tour-session-cli 100`. `/tmp/GetOverHere-guide-signature-100-2.log` passed 100/100 Swift→Kotlin and 100/100 Kotlin→Swift with exact retained ciphertext and changed/truncated rejection. A preceding invocation used a nonexistent guessed Swift output path and failed before testing; the corrected path came from the actual build output.

Full software gate attempts used `GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer GOH_IOS_DERIVED_DATA=/tmp/GetOverHereNearbyIOS GOH_IOS_DESTINATION='platform=iOS Simulator,id=A7202CAB-B085-4F1A-A7B5-8AE00A839E76' ANDROID_SERIAL=emulator-5554 bash scripts/verify_virtual_devices.sh`. The first pass reached Android instrumentation but its added native-cross check could not find the test runner after Gradle cleanup (`/tmp/GetOverHere-guide-signature-virtual.log`); the harness now explicitly reinstalls the built APK/test APK. That initial run also preceded the final source freeze and is not the final canonical-signature qualification.

The frozen-source rerun hit SpringBoard `FBSOpenApplicationErrorDomain Code=6 Busy` before simulator test launch (`/tmp/GetOverHere-guide-signature-virtual-final.log`). Stopped only that task's xcodebuild. Created isolated simulator `B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98` (`GOH-Signature-20260907`, iPhone 17 Pro, iOS 26.4.1), then repeated with `GOH_IOS_DERIVED_DATA=/tmp/GetOverHereSignatureIOS` and that destination (`/tmp/GetOverHere-guide-signature-isolated.log`). All nine host gates and iOS unit/integration passed: 109 tests, zero failures, one hardware-only skip per the 13-04-44 xcresult summary. The UI runner encountered the same Busy preflight denial; stopped only its xcodebuild. The full virtual gate is therefore **not green**. Permission to restart shared CoreSimulator services was requested, not assumed; the isolated simulator is retained for that retry.

Independent native check after reinstalling the current emulator APK/test APK: `python3 scripts/verify_guide_signatures_android.py /tmp/GetOverHereCoreParitySwift/out/Products/Debug/tour-session-swift /Users/aessam/Library/Android/sdk/platform-tools/adb emulator-5554`. `/tmp/GetOverHere-guide-signature-native.log` passed CryptoKit→Android and Android→CryptoKit verification plus 100 native key/signature/tamper checks. No private signing keys are exported. This proves the primitive/provider contract, not app pinning, live radio, replay/expiry policy, or relay delivery. Stable LAN tag remains untouched.

## 2026-09-07 — Resumed physical testing: dropped native admission reply

Baseline `477f244`. User explicitly approved the CoreSimulator restart and both unlocked physical Android phones, later confirming neither has a device passcode. iPhone remains unavailable. Identified CoreSimulatorService PID 1434, ran `kill -TERM 1434`, then `xcrun simctl list devices available`. No other service restarted. Repeated iOS UI command with Xcode beta, `-destination 'platform=iOS Simulator,id=B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98' -derivedDataPath /tmp/GetOverHereSignatureIOS -parallel-testing-enabled NO test -only-testing:GetOverHereUITests`; `/tmp/GetOverHere-477-ios-ui-restart.log` exited zero. The 14-14-58 xcresult summary reports four distinct tests passed, one skipped, zero failures (seven parameterized runs passed).

Command `GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh` failed admission at HEAD; artifacts `/tmp/GetOverHereNearbyPhysical.5MbFXU`, output `/tmp/GetOverHere-477-BLE-forward.log`. The dependent reverse/Aware commands did not execute. Radio settings were left unchanged. Instrumentation had exited before PID-based log collection; resolved each exact app UID via `pm list packages -U com.aessam.comeoverhere` and recovered only that app's logs with `logcat -d --uid`. The harness now uses this exact-package UID collection.

Added payload-free byte-count diagnostics and reran the same command: `/tmp/GetOverHere-BLE-admission-diagnostic.log`, artifacts `/tmp/GetOverHereNearbyPhysical.WOVARb`. Failed again. Guide `NearbyLane` recorded local EOF after forwarding 141 bytes; guest recorded native EOF after forwarding only 103 bytes. Admission challenge is 103 bytes and reply 38. The guide closed the native socket immediately on local EOF, before its queued final reply arrived at the guest.

Regression command `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' Android/gradlew -p Android :app:testDebugUnitTest --tests com.aessam.comeoverhere.NearbySocketBridgeTest.admissionReplyRemainsAvailableUntilNativePeerCloses` failed before the fix with `Local EOF discarded the pending native reply` (`/tmp/GetOverHere-admission-close-red.log`). Guide-side bounded drain implemented in Kotlin and Swift; no wire change. The full Kotlin bridge class passed afterward (`/tmp/GetOverHere-admission-close-green.log`). Added abandoned-peer deadline coverage on both platforms before final verification.

The simulator-recovery full gate (`GOH_XCODE_DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer GOH_IOS_DERIVED_DATA=/tmp/GetOverHereSignatureIOS GOH_IOS_DESTINATION='platform=iOS Simulator,id=B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98' ANDROID_SERIAL=emulator-5554 bash scripts/verify_virtual_devices.sh`) completed in `/tmp/GetOverHere-virtual-recovered.log`, including native cross-provider checks. This run overlapped development of the drain fix, so it establishes simulator recovery but is not the final frozen-source qualification. A fresh complete gate is required below.

Frozen-source Kotlin bridge class, including abandoned-peer timeout: `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' Android/gradlew -p Android :app:testDebugUnitTest --tests com.aessam.comeoverhere.NearbySocketBridgeTest`, `/tmp/GetOverHere-admission-drain-bounded.log`, passed six tests. Repeated the complete virtual command above: `/tmp/GetOverHere-admission-drain-virtual-final.log`. All host gates and iOS unit/integration passed; the 14-26-48 xcresult reports 110 distinct tests passed, one skipped, zero failures (114 parameterized runs passed). UI runner preflight then failed with SpringBoard Busy again. A scoped `simctl spawn ... log show` failed because the dedicated device was not booted; `simctl list devices available` confirmed shutdown. No second shared-service restart was performed. Read `simctl help bootstatus`, then ran `DEVELOPER_DIR=/Users/aessam/Downloads/Xcode-beta.app/Contents/Developer xcrun simctl bootstatus B9C1B1BA-6F9F-4B24-9EC7-095EF543DD98 -b` (`/tmp/GetOverHere-drain-sim-boot.log`) before another frozen-source full gate (`/tmp/GetOverHere-admission-drain-virtual-booted.log`).

Patched physical sequence uses the same script with explicit guide/guest serials, first Pixel 11 Pro→Pixel 7 BLE, then reversed BLE, then `GOH_NEARBY_TRANSPORT=aware` in both directions. No `GOH_NEARBY_WIFI_OFF` was set; both `settings get global wifi_on` values read `1` during this sequence. Forward BLE passed both instrumentation roles: artifacts `/tmp/GetOverHereNearbyPhysical.GAdhUQ`, `/tmp/GetOverHere-drain-BLE-forward.log`, guest 17.135 seconds. Reverse guest passed in 17.897 seconds (`/tmp/GetOverHereNearbyPhysical.X5vpWs/guest.txt`); full role completion is recorded below when the guide ends. Every passing guest asserts locked admission, authoritative pointer, byte-exact 512-byte asset, and 100 non-silent native-decoded frames; not microphone playback, background, endurance, scale, signed relay, or mixed-platform Aware proof.

Final frozen-source virtual gate after explicit boot passed completely: `/tmp/GetOverHere-admission-drain-virtual-booted.log`. UI xcresult `Test-GetOverHere-2026.09.07_14-31-24--0700.xcresult` reports four distinct tests passed, one hardware skip, zero failures (seven parameterized runs passed). Android instrumentation completed with zero failures and three explicit hardware/physical-fixture skips; the final CryptoKit↔Android native-provider check passed with 100 native key/signature/tamper checks. No production source changed after this qualification; the later APK-reuse option affects only the physical harness.

Reverse BLE completed both roles successfully (`/tmp/GetOverHere-drain-BLE-reverse.log`, `.X5vpWs`). Forward Aware passed (`/tmp/GetOverHere-drain-Aware-forward.log`, `.fxaitr`, guest 15.343 seconds). Both reverse Aware roles passed (`/tmp/GetOverHere-drain-Aware-reverse.log`, `.5Q5G7Y`, guest 17.439 seconds), but the script then failed parsing because I edited it while it was executing. That command is not a passing harness gate. The frozen retry with `GOH_NEARBY_REUSE_INSTALLED=1 GOH_NEARBY_TRANSPORT=aware GOH_NEARBY_GUIDE=2A111FDH2007A1 GOH_NEARBY_GUEST=66180DLKX006ND` failed before discovering an endpoint (`/tmp/GetOverHere-drain-Aware-reverse-final.log`, `.UBwZFO`). Preserve this intermittent failure rather than calling Aware stable. The fixture's generic error says Bluetooth even when its selected transport is Aware.

The new `GOH_NEARBY_REUSE_INSTALLED=1` path ran successfully against both devices. It verifies installed app SHA-256 `36676836177cd834a8ddba3c5a839b69508fde889fccfe3e528e3c1412093e7c` and test APK SHA-256 `af98e414aa0e1ac603b1f110f2712ee2a0242f280c0f11f5709c6e2d2eb17ebd` against the built artifacts before skipping reinstall. `bash -n scripts/verify_nearby_physical_android.sh` and `git diff --check` passed. Exact-package UID log collection also succeeded after instrumentation process exit.

Independent disabled-radio sequence: `GOH_NEARBY_REUSE_INSTALLED=1 GOH_NEARBY_WIFI_OFF=1 GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh`, then the same command with serials reversed. Both full harnesses passed: `/tmp/GetOverHere-drain-off-forward.log`, `.fHr7gL`, guest 13.772 seconds; `/tmp/GetOverHere-drain-off-reverse.log`, `.Bb0Yqa`, guest 15.648 seconds. Both original Wi-Fi states were `1`, disabled before joining, restored by each EXIT trap, and independently read back as `1` afterward. During the first guide window, scoped `dumpsys window` showed the guide asleep behind keyguard despite the fixture's activity flags. This does not qualify deliberate background/lock transitions, but invalidates an assumption that these runs were necessarily foreground throughout.

After the disabled-radio jobs exited, ran public `input keyevent KEYCODE_WAKEUP` and `wm dismiss-keyguard` on both user-confirmed passcode-free phones. Immediate snapshots showed awake displays but keyguard still present during dismissal. Read the public command help and [Android KeyguardManager contract](https://developer.android.com/reference/android/app/KeyguardManager): absence of a secure lock and whether keyguard is showing are separate states. No credentials, device policy, or secure lock configuration were changed. Repeated reverse Aware with verified installed APKs: `/tmp/GetOverHere-drain-Aware-awake.log`, `.Mv55is`, both roles passed, guest 13.752 seconds. A follow-up read-only foreground snapshot was not executed because automatic permission review timed out; the successful rerun therefore does not isolate keyguard as the cause. All test jobs ended. Stable LAN tag remains at `59b0402`.

## 2026-09-07 — Two-phone Android Aware throughput benchmark

Baseline `c1c18d0`, Pixel 11 Pro `66180DLKX006ND` and Pixel 7 `2A111FDH2007A1`, both API 37; emulator `emulator-5554` API 36. User requested throughput measurements in both directions and continued implementation of the remaining work. Native app owns the Aware connection/bridge; test-only `AwareBenchmarkProtocol` and `AwarePhysicalBenchmarkTest` own traffic/measurement; the bash/Python runner owns explicit device selection, deployment, timeouts, artifacts and summaries. Neither platform-neutral core nor production tour wire bytes are changed by the benchmark. No Internet test server, LAN fallback or raw-PHY claim. Native connection setup follows the [Android Aware network contract](https://developer.android.com/develop/connectivity/wifi/wifi-aware).

Runner: `bash scripts/benchmark_android_aware.sh --guide 66180DLKX006ND --guest 2A111FDH2007A1`. Default is three 10-second trials each of guide→guest, guest→guide and simultaneous traffic, then swapped guide roles. Four sockets traverse the production Aware owner and GOD1 asset adapter: protocol control, two bulk directions, and independent RTT probes. Synthetic 65,536-byte blocks carry exact sequences; every received byte is compared and both endpoints' byte counts must agree. Mbps is `received_bytes * 8000 / receive_nanoseconds`, including receive/drain time. Warm-up is separate. Foreground setup refuses secure-lock dismissal, requests dismissal only for a non-secure keyguard, then checks interactive screen, keyguard state and actual activity focus throughout. Results include model, API and native thermal status; this is not a battery/endurance experiment.

Initial emulator-only command added `--smoke-only`: `/tmp/GetOverHere-aware-benchmark-smoke.log`, artifacts `/private/var/folders/ll/cs92d_x12t77646gcv3n5t9h0000gn/T/GetOverHereAwareBenchmark.9n0o3u3s` (initial runner used the system temporary directory). Socket loopback, full-duplex byte checking, corruption rejection and percentile arithmetic passed. First physical pilot added `--millis 1000 --rounds 1`: `/tmp/GetOverHere-aware-benchmark-pilot.log`, `/tmp/GetOverHereAwareBenchmark.xlfku8gz`. Failed before data transfer. Both devices reported foreground ready; guide log recorded `Aware startup failed (BindException)`. Scoped `adb -s 66180DLKX006ND shell ss -tan` output for the relevant ports showed local port 50004 occupied by an unrelated established outgoing connection. No unrelated process or connection was changed.

Extracted the existing listener construction without changing its fixed-port behavior, then ran `AwareListenerPortTest.existingConnectionOnOldPortCannotBlockAwareListener` on the emulator. `/tmp/GetOverHere-aware-port-red.log` reproduced `EADDRINUSE`. Changed the active Android owner to allocate and advertise its assigned port; `/tmp/GetOverHere-aware-port-green.log` passed, and `/tmp/GetOverHere-aware-port-green-build.log` passed Android unit tests and both APK builds. Added native attach, publish/subscribe, peer-discovery and data-path-ready logs without PINs, keys, peer addresses or payloads. The runner now executes the occupied-port regression before every physical benchmark.

Corrected short pilot: `/tmp/GetOverHere-aware-benchmark-pilot-fixed.log`, `/tmp/GetOverHereAwareBenchmark.61f0s1ge`. Both guide orientations passed. One-second receiver goodput samples were 357.85/216.44 Mbps (Pixel 11 Pro guide down/up), 297.47/273.56 Mbps (Pixel 7 guide down/up); duplex was 196.12/151.34 and 135.65/193.28 Mbps respectively. These are preliminary single short samples, not final sustained measurements. Initial idle RTT sampling was only one second and is superseded by 100-sample idle measurement.

First extended run used `--reuse-installed --millis 10000 --rounds 3`: `/tmp/GetOverHere-aware-benchmark-measured.log`, `/tmp/GetOverHereAwareBenchmark.vk9vmv9e`. All nine forward transfer trials verified their blocks and counterpart byte totals, but the guest failed waiting for the final marker after the guide released its owner; the whole benchmark is failed, not accepted. A deterministic completion regression failed with `expected TimeoutException ... nothing was thrown` (`/tmp/GetOverHere-aware-bench-end-red.log`). The benchmark guide now waits for peer closure after writing completion; the guest closes after receiving it. Also increased idle sampling to 100 echoes. The earlier full software run `/tmp/GetOverHere-aware-benchmark-virtual.log` picked up the deliberately red completion test and failed that one test; it is not final qualification.

Final frozen benchmark command (fresh install, no reuse because test APK changed): `bash scripts/benchmark_android_aware.sh --guide 66180DLKX006ND --guest 2A111FDH2007A1 --millis 10000 --rounds 3`, `/tmp/GetOverHere-aware-benchmark-final.log`, `/tmp/GetOverHereAwareBenchmark.po2lx70k`. Its occupied-port, completion-lifetime and emulator protocol smoke gates passed before physical traffic. A separate frozen software gate uses the established simulator bootstatus/verify_virtual_devices commands and logs to `/tmp/GetOverHere-aware-benchmark-virtual-final.log`.

Final outcome: all 18 measured physical trials and both orientation completion checks passed. `manifest.json` records baseline `c1c18d013f47fb52f21694592622f6f98a4d984a` plus these uncommitted changes; app APK SHA-256 `783139bc2b5231b1a4d310e4619070eec6a86cc328d31b92b22a6e8a772bfe0a`, test APK SHA-256 `cc34a08e989d75f709f05ef51458abaaab747de60f29a02f8632a311bc744dfd`. Raw per-trial results and endpoint logs are in the artifact directory.

| Guide | Mode | Guide→guest Mbps min/median/max | Guest→guide Mbps min/median/max | Per-trial RTT p95 ms min/median/max |
| --- | --- | --- | --- | --- |
| Pixel 11 Pro | One-way down | 297.82 / 300.05 / 314.11 | — | 181.24 / 182.01 / 189.32 |
| Pixel 11 Pro | One-way up | — | 273.18 / 292.46 / 292.72 | 183.59 / 190.67 / 195.55 |
| Pixel 11 Pro | Duplex | 162.45 / 180.56 / 192.62 | 168.76 / 181.44 / 185.85 | 228.89 / 230.17 / 234.47 |
| Pixel 7 | One-way down | 302.59 / 307.41 / 312.48 | — | 185.58 / 189.52 / 197.14 |
| Pixel 7 | One-way up | — | 291.07 / 299.36 / 326.61 | 182.74 / 187.58 / 192.83 |
| Pixel 7 | Duplex | 174.96 / 185.69 / 192.39 | 176.71 / 181.37 / 194.80 | 218.67 / 223.68 / 231.36 |

Idle RTT used 100 samples per orientation: forward p50/p95 14.64/155.02 ms, reverse 17.47/171.04 ms. Guest-local all-four-channel setup was 2136.02/3989.98 ms. Native thermal status was 0 at recorded samples, and foreground/keyguard monitoring passed. Phones were USB-connected; distance/RF conditions and battery drain were not measured. Wi-Fi settings were unchanged and infrastructure association was not removed; explicit Aware network sockets, not LAN fallback, carried the payload. These results establish usable socket/bridge goodput, not raw PHY capacity or full-tour acoustic performance. Idle latency already has a tail; do not attribute all delay to concurrent assets.

Final frozen software gate passed all included stages, ending `Virtual-device verification passed; physical audio and radio gates remain separate`, including 100 native cross-provider signature checks. Production tour regression then ran `GOH_NEARBY_REUSE_INSTALLED=1 GOH_NEARBY_TRANSPORT=aware GOH_NEARBY_GUIDE=66180DLKX006ND GOH_NEARBY_GUEST=2A111FDH2007A1 bash scripts/verify_nearby_physical_android.sh` and repeated with serials reversed. Both full harnesses passed: `/tmp/GetOverHere-aware-dynamic-tour-forward.log` (guest 15.616 seconds) and `/tmp/GetOverHere-aware-dynamic-tour-reverse.log` (17.983 seconds). Each verifies real admission, authoritative control, byte-exact assets and non-silent native-decoded audio. Not microphone/speaker, locked-phone, endurance, group or relay qualification. No production/test sources changed after these frozen runs.

## 2026-09-07 — Research archival and complete next-session handoff

User supplied complete Claude and ChatGPT reports self-dated 8 September 2026, then requested both reports/references and all completed/planned work in NextSession.md. Preserve the author dates as attribution, not new local experiment timestamps. Archived [Claude](Research-Claude-2026-09-08.md) and [ChatGPT](Research-ChatGPT-2026-09-08.md) report bodies and source lists, with provenance warnings. Replaced the active handoff with current C1–C13 completion inventory, verified benchmark/software/physical evidence, F1–F6 corrections, ordered A1–A4 plan, pending scope decisions, device/SDK paths and exact resume commands. Preserved every prior checkpoint and P0–P8 gate in [NextSession-History.md](NextSession-History.md). ADR-058 and lesson 84 record the research adjudication.

Read-only evidence checks: `git status --short`, `git log -8 --oneline`, `git rev-parse HEAD 'stable-local-network^{}'`; `tail -n 10 /tmp/GetOverHere-aware-benchmark-final.log`; `tail -n 3 /tmp/GetOverHere-aware-benchmark-virtual-final.log`; source inspection of `NearbyTCPConnection` and `NearbySocketBridge`. Baseline implementation remains `7dca55f`, stable tag `59b0402`. Prior synthesis opened Apple DTS 787570, Android PublishConfig.Builder and Apple WWDC25 session 228, confirming background execution/suspension distinction, documented version-37.2 offloaded pairing, and realtime/voice performance controls. It did not rerun every external report citation or test device availability for the newer pairing API.

No app/test/build-script changes, device/radio operations, new benchmarks, SDK installation, service restart, paid resources or physical qualification were performed for the documentation request. An initial combined move-and-add patch for NextSession.md was rejected because it targeted the same path twice; split into separate successful patches without discarding history. Documentation integrity checks and checkpoint result follow below.

Documentation checks passed: local Markdown targets in the handoff/history/reports resolve; `git show HEAD:NextSession.md | tail -n +3 | diff - <(tail -n +5 NextSession-History.md)` returned no differences (all historical content retained after the replaced title/provenance header). Section checks found C1–C13, F1–F6 and A1–A4 in the active handoff and all report top-level sections. Scoped `awk` checks counted all 24 ChatGPT source entries and 14 Claude source-list entries. Re-read socket source confirms TCP_NODELAY and the 32-connection default. Existing tracked-file `git diff --check` passed. Archive Markdown hard-break whitespace is intentionally retained; the staged Markdown whitespace check ignores end-of-line spaces only. No new app test run is claimed for this documentation-only change.
