# Repository Guidelines

## Project Structure & Module Organization

This is a native iOS/Android monorepo. Apple code lives in `iOS/GetOverHere/`: transport and networking primitives are under `Core/`, application services under `Services/`, data types under `Models/`, SwiftUI screens under `Views/`, and navigation under `Navigation/`. Unit and UI tests are in `iOS/GetOverHereTests/` and `iOS/GetOverHereUITests/`; assets are in `Assets.xcassets`.

Android code lives in `Android/app/src/main/java/com/aessam/comeoverhere/`, split into `core/`, `service/`, and `ui/`. Local unit tests use `app/src/test/`; device tests use `app/src/androidTest/`. Keep cross-platform transport messages and wire behavior aligned between Swift and Kotlin. Record architecture changes in `ADR.md` and significant debugging outcomes in `LessonsLearned.md`.

## Build, Test, and Development Commands

- `xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` builds iOS from the command line.
- `xcodebuild -project iOS/GetOverHere.xcodeproj -scheme GetOverHere -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` runs iOS unit and UI tests.
- `cd Android && ./gradlew assembleDebug` creates the Android debug APK.
- `cd Android && ./gradlew testDebugUnitTest` runs JVM unit tests.
- `cd Android && ./gradlew connectedDebugAndroidTest` runs instrumented tests on a connected device or emulator.

Use physical devices for BLE, Wi-Fi Aware, and end-to-end audio verification; simulators do not prove those paths.

## Coding Style & Naming Conventions

Follow existing Xcode and Kotlin formatting: four-space indentation, one primary type per file, and no wildcard imports in new code. Use `UpperCamelCase` for types, `lowerCamelCase` for members, and descriptive role suffixes such as `Service`, `Transport`, `Screen`, and `View`. Prefer protocols/interfaces at platform boundaries, structured concurrency, and explicit error reporting. Do not silently fall back when networking or serialization fails.

## Testing Guidelines

Use Swift Testing (`@Test`, `#expect`) for iOS unit tests and XCTest only for UI automation. Android unit tests use JUnit 4 and coroutine test utilities; device tests use AndroidX JUnit/Espresso. Name tests after observable behavior. Add round-trip tests for every wire-format change and cover the equivalent behavior on both platforms.

## Commit & Pull Request Guidelines

History uses concise imperative subjects, optionally prefixed by the affected area, for example `Fix: ...`, `iOS UDP: ...`, or `Monorepo: ...`. Keep commits focused and never add co-authors. Pull requests must explain behavior and protocol impact, list commands and devices tested, link relevant issues or ADR entries, and include screenshots for UI changes.
