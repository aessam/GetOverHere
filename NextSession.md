# Next Session

**Date:** 2026-08-21
**Status:** Shared-screen fix is installed on both devices; physical acceptance is blocked while Dark knight remains locked.

## Proven

- Complete seven-stage verifier passes with 16 Swift core tests, 16 Kotlin core tests, exact cross-language bytes/auth/state/shared-screen behavior, 1/8/20/50 churn, 23 Android JVM tests plus APK, and 23 iOS Simulator tests.
- Pixel 11 Pro connected suite passes 6/6: private/speaker routes, processed guide capture, PMTiles rendering, application context, Activity recreation survival, and guide Map/Pointer publication.
- Target and bearing delivery now includes an authoritative versioned Slides/Map/Pointer screen selection. Real TCP, stale-state, late-join, map-asset, and platform UI regressions pass.
- Latest Android APK and signed iOS app are installed. Android launched; latest iOS launch is unverified because Dark knight locked after installation.
- Both platform UI tests now exercise the explicit missing-offline-map state; the requirement audit found no additional production-code omission.

## Next actions

1. Unlock Dark knight and leave it on the Home Screen.
2. Open the installed iPhone app and verify slide → Map → Pointer follows the guide immediately.
3. Run the physical iPhone PMTiles test.
4. Execute both guide directions across iOS and Android: audio, listener count, slide import/presentation, target pin/local guidance, sightline pointer, background/lock, leave/rejoin, and session restart.
5. Record direct evidence in `ExperimentLog.md` and ask the deferred product questions.
