#!/bin/bash
# WebDriverAgent (tools/wda, BSD) as a long-lived XCUITest command server on a physical iPhone.
# Usage: scripts/wda.sh start|stop|status|url  (DEVICE=<udid>, default the iPhone 13 Pro test phone)
# Reached over the CoreDevice USB tunnel (no Wi-Fi, no Bluetooth). Build once with scripts/wda.sh build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-00008110-000528410CF8801E}"
DERIVED="${WDA_DERIVED:-/tmp/GetOverHerePhase5/wda}"
LOG="$DERIVED/wda-runner.log"
PIDFILE="$DERIVED/wda-runner.pid"

tunnel_url() {
    local json; json="$(mktemp)"
    xcrun devicectl device info details --device "$DEVICE" --json-output "$json" >/dev/null 2>&1 || { rm -f "$json"; echo "error: device $DEVICE unavailable" >&2; exit 1; }
    local address; address="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["connectionProperties"]["tunnelIPAddress"])' "$json")"
    rm -f "$json"
    [[ -n "$address" ]] || { echo "error: no USB tunnel address for $DEVICE" >&2; exit 1; }
    echo "http://[$address]:8100"
}

case "${1:-}" in
  build)
    cd "$ROOT/tools/wda/packages/webdriveragent"
    xcodebuild -quiet -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
        -destination "platform=iOS,id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM=VW9YC3A6JM CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=com.aens.WebDriverAgentRunner \
        build-for-testing ;;
  start)
    manifest="$(ls "$DERIVED"/Build/Products/WebDriverAgentRunner_*.xctestrun 2>/dev/null | head -1)"
    [[ -n "$manifest" ]] || { echo "error: run scripts/wda.sh build first" >&2; exit 1; }
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "already running"; exit 0; fi
    nohup xcodebuild -xctestrun "$manifest" -destination "platform=iOS,id=$DEVICE" test-without-building > "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    url="$(tunnel_url)"
    for _ in $(seq 1 90); do
        if curl -s --max-time 2 "$url/status" | grep -q '"ready" *: *true'; then echo "WDA ready at $url"; exit 0; fi
        kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { tail -20 "$LOG" >&2; echo "error: WDA runner exited" >&2; exit 1; }
        sleep 2
    done
    tail -20 "$LOG" >&2; echo "error: WDA did not become ready" >&2; exit 1 ;;
  stop)
    if [[ -f "$PIDFILE" ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
    echo stopped ;;
  status) curl -s --max-time 3 "$(tunnel_url)/status" ;;
  url) tunnel_url ;;
  *) echo "usage: $0 build|start|stop|status|url" >&2; exit 1 ;;
esac
