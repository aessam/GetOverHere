#!/usr/bin/env python3
"""USB-run BLE benchmark: one iPhone and one/two Androids, synthetic verified bytes, no LAN."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios", required=True)
    parser.add_argument("--android", required=True, nargs="+")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--ios-role", choices=["guide", "guest"], required=True)
    parser.add_argument("--bytes", type=int, default=65536)
    args = parser.parse_args()
    if (len(set(args.android)) != len(args.android) or not 1 <= len(args.android) <= 2 or
            args.ios_role == "guest" and len(args.android) != 1 or
            args.bytes not in (1024, 16384, 65536, 131072, 262144)):
        parser.error("Choose one/two distinct Androids (two only with iPhone guide), and a bounded block size")
    root = Path(__file__).resolve().parent.parent
    adb = str(Path.home() / "Library/Android/sdk/platform-tools/adb")
    artifacts = Path(tempfile.mkdtemp(prefix="GetOverHereBluetoothSpeed.", dir="/tmp"))
    print(f"Artifacts: {artifacts}", flush=True)
    room = str(uuid.uuid4())
    provenance = {"started_utc": datetime.now(timezone.utc).isoformat(),
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True)),
        "sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in (
            root / "Android/app/build/outputs/apk/debug/app-debug.apk",
            root / "Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk",
            args.manifest.parent / "Debug-iphoneos/GetOverHere.app/GetOverHere.debug.dylib",
            args.manifest.parent / "Debug-iphoneos/GetOverHere.app/PlugIns/GetOverHereTests.xctest/GetOverHereTests")}}
    for serial in args.android:
        subprocess.run([adb, "-s", serial, "get-state"], check=True, timeout=10)
        for package, apk in (("com.aessam.comeoverhere", "apk/debug/app-debug.apk"),
                             ("com.aessam.comeoverhere.test", "apk/androidTest/debug/app-debug-androidTest.apk")):
            local = root / "Android/app/build/outputs" / apk
            installed = subprocess.check_output([adb, "-s", serial, "shell", "pm", "path", package], text=True, timeout=15).strip()
            if re.fullmatch(r"package:/data/app/[A-Za-z0-9/._=+~-]+/base\.apk", installed):
                digest = subprocess.check_output([adb, "-s", serial, "shell", "sha256sum", installed.removeprefix("package:")],
                    text=True, timeout=15).split()[0]
                if digest == hashlib.sha256(local.read_bytes()).hexdigest():
                    print(f"Verified installed SHA-256: {serial} {package}", flush=True)
                    continue
            subprocess.run([adb, "-s", serial, "install", "-r", str(local)], check=True, timeout=180)
    with args.manifest.open("rb") as file:
        manifest = plistlib.load(file)
    for configuration in manifest["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target.get("BlueprintName") == "GetOverHereTests":
                target.setdefault("EnvironmentVariables", {}).update({"GOH_SPEED_ROLE": args.ios_role,
                    "GOH_SPEED_ROOM": room, "GOH_SPEED_BYTES": str(args.bytes), "GOH_SPEED_PEERS": str(len(args.android))})
    descriptor, temporary = tempfile.mkstemp(prefix="speed-", suffix=".xctestrun", dir=args.manifest.parent)
    processes, files = [], []
    try:
        with os.fdopen(descriptor, "wb") as file:
            plistlib.dump(manifest, file)
        commands = {"ios": ["xcodebuild", "-xctestrun", temporary, "-destination", f"platform=iOS,id={args.ios}",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(artifacts / "ios.xcresult"),
            "test-without-building", "-only-testing:GetOverHereTests/BluetoothSpeedTests/measure()"]}
        for serial in args.android:
            commands[serial] = [adb, "-s", serial, "shell", "am", "instrument", "-w", "-r", "-e", "class",
                "com.aessam.comeoverhere.BluetoothSpeedTest#measure", "-e", "speedRoom", room,
                "-e", "speedRole", "guest" if args.ios_role == "guide" else "guide", "-e", "speedBytes", str(args.bytes),
                "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner"]
        (artifacts / "run.json").write_text(json.dumps({"ios": args.ios, "android": args.android,
            "ios_role": args.ios_role, "bytes_per_trial": args.bytes, "rounds": 3,
            "transport": "Bluetooth L2CAP with guide-side loopback adapter; no tour encryption or codec",
            "scope": "pairwise" if len(args.android) == 1 else "two concurrent listeners, independently started trials",
            "commands": commands, "provenance": provenance}, indent=2))
        for name, command in commands.items():
            log = (artifacts / f"{name}.log").open("w"); files.append(log)
            processes.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT))
        deadline = time.monotonic() + 240
        statuses = [process.wait(timeout=max(1, deadline - time.monotonic())) for process in processes]
        for file in files: file.flush()
        result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(artifacts / "ios.xcresult")],
            capture_output=True, text=True, check=True)
        summary = json.loads(result.stdout)
        (artifacts / "summary.json").write_text(result.stdout)
        rows = []
        for name in commands:
            content = (artifacts / f"{name}.log").read_text()
            for line in content.splitlines():
                marker = "BLUETOOTH_SPEED " if name == "ios" else "INSTRUMENTATION_STATUS: bluetooth_speed="
                if marker in line:
                    rows.append(dict(json.loads(line.split(marker, 1)[1]), reporter=name))
        (artifacts / "results.json").write_text(json.dumps(rows, indent=2))
        expected = 7 * (len(args.android) if args.ios_role == "guide" else 1)
        if (any(statuses) or summary["passedTests"] != 1 or summary["failedTests"] or summary["skippedTests"] or
                len(rows) != expected or any("OK (1 test)" not in (artifacts / f"{serial}.log").read_text() for serial in args.android)):
            raise RuntimeError(f"Incomplete/failed speed test: {artifacts}")
        print(f"PASS: verified Bluetooth speed results: {artifacts / 'results.json'}", flush=True)
    finally:
        for process in processes:
            if process.poll() is None: process.terminate(); process.wait(timeout=10)
        for file in files: file.close()
        Path(temporary).unlink()


if __name__ == "__main__":
    main()
