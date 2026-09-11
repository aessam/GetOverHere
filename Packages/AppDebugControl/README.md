# iPhone debug control

Debug-only SPM library and Mac client. The iOS adapter uses the scene's actual
`AppCoordinator` and production services. It does not simulate taps, grant permissions,
unlock the phone, or create a second coordinator. XCTest remains the visual UI check.

## Start

Build/install the Debug app with Xcode and build the client:

```sh
swift build --package-path Packages/AppDebugControl --product goh-control
DEBUG_CREDENTIALS=$(mktemp -d /tmp/GetOverHereDebug.XXXXXX)
bash scripts/create_debug_control_identity.sh "$DEBUG_CREDENTIALS"
python3 scripts/start_iphone_debug_control.py DEVICE_ID "$DEBUG_CREDENTIALS"
```

The launch helper requires the app not already running to apply its environment.
Quit normally first; the helper never force-stops it. Only explicitly enabled launches
start the listener. Debug identity import requires iOS 18+; the normal app baseline is unchanged.

Open `goh-debug://panel` to see the address/port, or copy the non-secret
`Library/Caches/DebugControl/endpoint.json` from the app container with `devicectl`.
The URL opens diagnostics only; it cannot execute commands or supply credentials.
Devices on different SSIDs/VLANs still require actual bidirectional routing to TCP 50999.
An endpoint file is a last observation, not a liveness check.

```sh
DEBUG_CLI=$(swift build --package-path Packages/AppDebugControl --show-bin-path)/goh-control
python3 scripts/goh_control.py PHONE_IP "$DEBUG_CREDENTIALS" status --cli "$DEBUG_CLI"
python3 scripts/goh_control.py PHONE_IP "$DEBUG_CREDENTIALS" show-debug --cli "$DEBUG_CLI"
python3 scripts/goh_control.py PHONE_IP "$DEBUG_CREDENTIALS" wait --field audio --equals running --timeout 20 --cli "$DEBUG_CLI"
python3 scripts/verify_iphone_debug_control.py PHONE_IP "$DEBUG_CREDENTIALS" --cli "$DEBUG_CLI" --create-room
```

The last command intentionally starts microphone capture, checks room controls, and
ends its own test room. Run only with permission. If the connection fails during
cleanup, end the room on the phone; it cannot clean up through an unavailable network.

Commands: `status`, `discover`, `create name=`, `join id= [code=]`, `leave`,
`cancel-join`, `room-lock locked=true|false [code=]`,
`feature name=slides|map|pointer`, `next-slide`, `previous-slide`, `retry-audio`,
`restart-microphone`, `discovery bluetooth=true|false aware=true|false`,
`output mode=privateAudio|speaker`, `show-create`, `show-debug`, `dismiss`.
Unknown commands/arguments fail closed. Mutation requires the foreground app.
A reply means the coordinator accepted the action, not that asynchronous work finished:
use `wait` for audio/join/lock completion. `watch --timeout 20` samples status.
Use `GOH_CONTROL_VERBOSE=1` for connection-state diagnostics. Do not put real room
codes in shared shell history; CLI arguments can be visible to local process inspection.

## Boundary

TLS 1.3 with an ephemeral pinned certificate; HMAC-SHA256 authenticates each request.
32-byte random key, owner-only credential files, no trust-store/keychain installation.
Secrets travel in the launch environment, not URL arguments. Keep the credential
directory private and remove it when finished. Neither requests nor keys are logged.
UUID replay rejection, 32 KiB frames, four connections, 10-second connection deadlines,
2,048 requests and a 15-minute activation limit bound the bridge.

The debug session keeps the foreground screen awake and restores its previous
idle-timer value when stopped/expired. Manual lock or switching apps may suspend it;
there is no background entitlement or silent-audio workaround. Stop from the panel.
Release uses the original plist without the URL scheme and compiles out the server,
adapter and panel. Do not expose this development endpoint to the Internet.

Tests: `swift test --package-path Packages/AppDebugControl` checks actual pinned TLS,
repeated connections, wrong key, wrong pin, replay rejection and Unicode roundtrip.
`DebugAppControlTests` covers adapter identity, disabled launch and rejection.
The opt-in UI test `testObserveExistingDebugControlSession` activates an existing app,
asserts its debug panel or pointer selection and retains a screenshot; it does not
launch a substitute app state. Set runner `GOH_OBSERVE_DEBUG_CONTROL=1` and optionally
`GOH_DEBUG_EXPECT_SCREEN=pointer` in an isolated xctestrun manifest.
