# iOS final ownership and UI gate

`ownership-summary.json` is the public xcresulttool summary from
`/tmp/GetOverHereGatewayIOS-ownership-final.xcresult`:9 test definitions passed,
zero failed/skipped. Swift Testing's parameterized stop/replacement case accounts
for10 actual runs. The selection includes wired transport/recovery/security,
lifecycle and the production Gateway setup UI.

```sh
DEVELOPER_DIR=/Users/aessam/Downloads/Xcode.app/Contents/Developer xcrun xcresulttool get test-results summary --path /tmp/GetOverHereGatewayIOS-ownership-final.xcresult
```

An earlier extended selection passed26 definitions/28 runs, including existing
asset cache/hash/resume tests, in
`/tmp/GetOverHereGatewayIOS-recovery-final.xcresult`. The final full app-unit gate
is reported separately in the parent report.

Address replacement uses an injected locator with actual TLS sockets on configured
loopback addresses127.0.0.1 and::1, retained certificate pins and a new generation.
It also verifies wrong-certificate rejection, exact asset tail bytes from offset387,
interruption cleanup, surviving independent local endpoints and stale descriptor
rejection after stop/replacement. An earlier127.0.0.2 test failed because that
address was not configured; no interface aliases were added to make it pass.

Native Bonjour matching/cancellation is component-tested. Actual cross-platform
USB mDNS, cable/DHCP changes, radio coexistence and physical listening remain NOT RUN.
No physical phone operations were performed by these simulator gates.
