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
