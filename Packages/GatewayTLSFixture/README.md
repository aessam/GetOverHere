# Gateway TLS interoperability fixture

Test-only Mac executable using the same LocalLinkSecurity certificate and
Network.framework TLS options as the iOS app. Android's selected instrumentation
test uses the production AndroidKeyStore/JSSE HubIdentity. Neither application
links this executable.

The test runs both server orientations. Each round-trips65,536 deterministic
bytes and verifies the exact SHA-256 at both endpoints. This is compatibility
evidence, not a bandwidth benchmark or physical USB/radio/audio qualification.

Build the Mac fixture and Android debug/test APKs. Install those APKs only on an
idle test emulator; the controller intentionally refuses physical phone IDs.
Coordinate emulator ownership before starting. It creates fresh test-only keys,
removes them afterwards, and removes only the ADB tunnels it created.

```sh
swift build --package-path Packages/GatewayTLSFixture
# Determine the executable directory; Swift build systems can differ:
swift build --package-path Packages/GatewayTLSFixture --show-bin-path
python3 scripts/verify_gateway_tls_interop.py --serial emulator-5554 --adb /Users/aessam/Library/Android/sdk/platform-tools/adb --binary /ABSOLUTE/BUILD/PATH/gateway-tls-fixture --apk Android/app/build/outputs/apk/debug/app-debug.apk --test-apk Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk --output /tmp/gateway-tls-interop-run
```

Use a new output directory for every run. Retained logs include both native
test results, public certificate fingerprints, payload hashes and scoped cleanup.
Preflight compares both installed APK hashes to the selected artifacts and records
the Mac executable hash, emulator OS and source-tree observation. That observation
is not an assertion that a concurrently edited tree produced an earlier binary.
No hub private key or tour credential leaves the device. Authentication rejection
cases are covered separately by LocalLinkSecurityTests and WiredHubTLSIdentityTest;
this fixture checks successful cross-runtime exchanges in both server roles.
