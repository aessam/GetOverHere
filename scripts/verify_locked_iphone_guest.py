#!/usr/bin/env python3
"""Phase 5 locked-guest run: Android guide (instrumentation), iPhone guest (debug bridge) over Bluetooth.

The iPhone joins with route policy `bluetooth`, then its idle timer is restored and Auto-Lock set to
30 seconds through a UI test so the phone locks by itself. Status is polled over the USB tunnel every
10 s. A window with no new renderer bytes is a stall. Auto-Lock is restored to its previous value.
Evidence: <artifacts>/status.jsonl, summary.json, android.log, autolock-*.log, lock-*.jpg.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
ADB = str(Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))) / "platform-tools/adb")


def control(args, command, *arguments, check=True):
    result = subprocess.run([args.cli, args.host, str(args.credentials / "control.key"), command, *arguments],
                            text=True, capture_output=True, timeout=15)
    if result.returncode:
        if check:
            raise RuntimeError(f"goh-control {command} failed: {(result.stderr or result.stdout).strip()}")
        return None
    return json.loads(result.stdout)


def wait_for(args, description, predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = control(args, "status", check=False)
        if state is not None and predicate(state):
            return state
        time.sleep(1)
    raise RuntimeError(f"Timed out: {description}")


def set_autolock(args, artifacts, value, label):
    log = artifacts / f"autolock-{label}.log"
    manifest = tempfile.NamedTemporaryFile(prefix="autolock-", suffix=".xctestrun", dir=args.manifest.parent, delete=False)
    try:
        import plistlib
        with args.manifest.open("rb") as file:
            plan = plistlib.load(file)
        for configuration in plan["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                if target.get("BlueprintName") == "GetOverHereUITests":
                    target.setdefault("EnvironmentVariables", {})["GOH_AUTOLOCK"] = value
        plistlib.dump(plan, manifest)
        manifest.close()
        with log.open("w") as output:
            status = subprocess.run(["xcodebuild", "-xctestrun", manifest.name, "-destination", f"platform=iOS,id={args.ios}",
                                     "-parallel-testing-enabled", "NO", "test-without-building",
                                     "-only-testing:GetOverHereUITests/GetOverHereUITests/testPhysicalSetAutoLock"],
                                    stdout=output, stderr=subprocess.STDOUT, timeout=300).returncode
    finally:
        Path(manifest.name).unlink(missing_ok=True)
    text = log.read_text()
    previous = re.search(r"GOH_AUTOLOCK_PREVIOUS=(.*)", text)
    if status or "** TEST SUCCEEDED **" not in text:
        raise RuntimeError(f"Auto-Lock change to {value!r} failed; see {log}")
    return previous.group(1).strip() if previous else None


def snapshot(args, path):
    """USB screen capture (no Bluetooth). Optional evidence that the screen actually locked."""
    if not args.screencap:
        return
    subprocess.run([args.screencap, str(path), args.ios_name], capture_output=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ios")
    parser.add_argument("android")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("credentials", type=Path)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--host", required=True, help="iPhone debug endpoint, e.g. the USB tunnel address")
    parser.add_argument("--listen-seconds", type=int, default=600)
    parser.add_argument("--screencap", help="ReCont Scripts/snap.sh for USB screen evidence")
    parser.add_argument("--ios-name", default="WorkTest001")
    args = parser.parse_args()
    for path in (args.cli, args.credentials / "control.key", args.manifest):
        if not Path(path).exists():
            parser.error(f"Missing {path}")
    artifacts = Path(tempfile.mkdtemp(prefix="GetOverHereLockedGuest-"))
    print(f"Artifacts: {artifacts}", flush=True)
    name = "Lock-" + uuid.uuid4().hex[:10]
    for apk in ("apk/debug/app-debug.apk", "apk/androidTest/debug/app-debug-androidTest.apk"):
        subprocess.run([ADB, "-s", args.android, "install", "-r", str(ROOT / "Android/app/build/outputs" / apk)], check=True)
    subprocess.run([ADB, "-s", args.android, "shell", "input", "keyevent", "KEYCODE_WAKEUP"], check=True)
    subprocess.run([ADB, "-s", args.android, "shell", "wm", "dismiss-keyguard"], check=True)
    hold = args.listen_seconds + 240
    android = subprocess.Popen([ADB, "-s", args.android, "shell", "am", "instrument", "-w", "-r",
        "-e", "class", "com.aessam.comeoverhere.NearbyLiveSessionTest", "-e", "nearbyRole", "guide",
        "-e", "nearbyRoomName", name, "-e", "nearbyHoldSeconds", str(hold),
        "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner"],
        stdout=(artifacts / "android.log").open("w"), stderr=subprocess.STDOUT)
    previous_autolock = None
    summary = {"room": name, "listenSeconds": args.listen_seconds, "windows": []}
    try:
        subprocess.run([sys.executable, str(ROOT / "scripts/start_iphone_debug_control.py"), args.ios,
                        str(args.credentials), "--relaunch"], check=True, timeout=60)
        wait_for(args, "debug endpoint", lambda s: s.get("sessionState") == "idle", 60)
        control(args, "route-policy", "policy=bluetooth")
        control(args, "discovery", "bluetooth=true", "aware=false")
        control(args, "discover")
        state = wait_for(args, "Android room over Bluetooth",
                         lambda s: any(r.get("name") == name and r.get("joinable") for r in s.get("rooms", [])), 120)
        room = next(r for r in state["rooms"] if r.get("name") == name)
        control(args, "join", f"id={room['id']}")
        state = wait_for(args, "guest audio over Bluetooth",
                         lambda s: s.get("activeRoute") == "bluetooth" and "running" in str(s.get("audio", "")).lower()
                         and s.get("acceptedPlaybackBytes", 0) > 0, 120)
        summary["routePolicy"] = state.get("routePolicy")
        control(args, "debug-keep-awake", "enabled=false")
        previous_autolock = set_autolock(args, artifacts, "30 seconds", "set")
        summary["autoLockPrevious"] = previous_autolock
        snapshot(args, artifacts / "lock-start.jpg")
        last = control(args, "status")["acceptedPlaybackBytes"]
        with (artifacts / "status.jsonl").open("w") as log:
            for window in range(1, args.listen_seconds // 10 + 1):
                time.sleep(10)
                state = control(args, "status", check=False)
                row = {"t": window * 10, "reachable": state is not None}
                if state is not None:
                    current = state.get("acceptedPlaybackBytes", 0)
                    row.update(delta=current - last, route=state.get("activeRoute"), audio=state.get("audio"),
                               connection=state.get("connection"), error=state.get("error"))
                    last = current
                log.write(json.dumps(row) + "\n")
                log.flush()
                summary["windows"].append(row)
                if window == 9:
                    snapshot(args, artifacts / "lock-90s.jpg")
    finally:
        try:
            if previous_autolock:
                set_autolock(args, artifacts, previous_autolock, "restore")
                summary["autoLockRestored"] = previous_autolock
        except Exception as error:  # Restoration failure must be reported, never hidden.
            summary["autoLockRestoreError"] = str(error)
            print(f"ERROR: Auto-Lock not restored to {previous_autolock!r}: {error}", file=sys.stderr)
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", args.ios, "--activate",
                        "com.aens.GetOverHere"], capture_output=True, timeout=30)
        control(args, "leave", check=False)
        control(args, "debug-keep-awake", "enabled=false", check=False)
        android.wait(timeout=hold + 120)
    measured = [w for w in summary["windows"] if w.get("reachable")]
    summary["stalledAt"] = [w["t"] for w in measured if w.get("delta", 0) <= 0]
    summary["unreachableAt"] = [w["t"] for w in summary["windows"] if not w.get("reachable")]
    summary["nonBluetoothAt"] = [w["t"] for w in measured if w.get("route") != "bluetooth"]
    summary["androidOK"] = "OK (1 test)" in (artifacts / "android.log").read_text()
    (artifacts / "summary.json").write_text(json.dumps(summary, indent=2))
    passed = (summary["androidOK"] and measured and not summary["stalledAt"] and not summary["nonBluetoothAt"]
              and "autoLockRestoreError" not in summary)
    print(json.dumps({k: v for k, v in summary.items() if k != "windows"}), flush=True)
    print(("PASS" if passed else "FAIL") + f": locked iPhone guest; {artifacts}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
