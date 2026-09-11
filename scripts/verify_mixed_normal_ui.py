#!/usr/bin/env python3
"""Authorized two-phone takeover: real Create/Find/Join UI, bounded fixtures, retained evidence."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ios")
    parser.add_argument("android")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--ios-role", choices=["guide", "guest"], required=True)
    args = parser.parse_args()
    adb = str(Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))) / "platform-tools/adb")
    root = Path(__file__).resolve().parent.parent
    artifacts = Path(tempfile.mkdtemp(prefix="GetOverHereNormalUI-"))
    print(f"Artifacts: {artifacts}", flush=True)
    name = "UI-" + uuid.uuid4().hex[:12]
    with args.manifest.open("rb") as file:
        manifest = plistlib.load(file)
    for configuration in manifest["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target.get("BlueprintName") == "GetOverHereUITests":
                target.setdefault("EnvironmentVariables", {}).update({"GOH_NORMAL_UI_ROLE": args.ios_role, "GOH_NORMAL_UI_ROOM": name})
    for apk in ("apk/debug/app-debug.apk", "apk/androidTest/debug/app-debug-androidTest.apk"):
        subprocess.run([adb, "-s", args.android, "install", "-r", str(root / "Android/app/build/outputs" / apk)], check=True)
    descriptor, temporary = tempfile.mkstemp(prefix="normal-ui-", suffix=".xctestrun", dir=args.manifest.parent)
    processes = []
    try:
        with os.fdopen(descriptor, "wb") as file:
            plistlib.dump(manifest, file)
        with (artifacts / "ios.log").open("w") as ios_log, (artifacts / "android.log").open("w") as android_log:
            ios = subprocess.Popen(["xcodebuild", "-quiet", "-xctestrun", temporary, "-destination", f"platform=iOS,id={args.ios}",
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(artifacts / "ios.xcresult"),
                "test-without-building", "-only-testing:GetOverHereUITests/GetOverHereUITests/testPhysicalMixedRoomThroughNormalUI"], stdout=ios_log, stderr=subprocess.STDOUT)
            processes.append(ios)
            android = subprocess.Popen([adb, "-s", args.android, "shell", "am", "instrument", "-w", "-r",
                "-e", "class", "com.aessam.comeoverhere.NearbyLiveSessionTest", "-e", "nearbyUI", "true",
                "-e", "nearbyRole", "guest" if args.ios_role == "guide" else "guide", "-e", "nearbyRoomName", name,
                "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner"], stdout=android_log, stderr=subprocess.STDOUT)
            processes.append(android)
            deadline = time.monotonic() + 240
            statuses = [process.wait(timeout=max(1, deadline - time.monotonic())) for process in processes]
        summary = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(artifacts / "ios.xcresult")], capture_output=True, text=True, check=True)
        (artifacts / "summary.json").write_text(summary.stdout)
        result = json.loads(summary.stdout)
        android_text = (artifacts / "android.log").read_text()
        if any(statuses) or result["passedTests"] != 1 or result["skippedTests"] or result["failedTests"] or "OK (1 test)" not in android_text:
            raise RuntimeError(f"Mixed UI gate failed; inspect {artifacts}")
        print(f"PASS: normal UI, iPhone {args.ios_role}; {artifacts}", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        Path(temporary).unlink()


if __name__ == "__main__":
    main()
