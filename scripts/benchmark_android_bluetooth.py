#!/usr/bin/env python3
"""Run the same GBB1 Bluetooth speed protocol on two physical Android phones."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guide", required=True)
    parser.add_argument("--guest", required=True)
    args = parser.parse_args()
    if args.guide == args.guest or any(x.startswith("emulator-") for x in (args.guide, args.guest)):
        parser.error("Two distinct physical phones required")
    root = Path(__file__).resolve().parent.parent
    adb = str(Path.home() / "Library/Android/sdk/platform-tools/adb")
    artifacts = Path(tempfile.mkdtemp(prefix="GetOverHereAndroidBluetoothSpeed.", dir="/tmp"))
    print(f"Artifacts: {artifacts}", flush=True)
    for serial in (args.guide, args.guest):
        subprocess.run([adb, "-s", serial, "get-state"], check=True, timeout=10)
        for package, apk in (("com.aessam.comeoverhere", "apk/debug/app-debug.apk"),
                             ("com.aessam.comeoverhere.test", "apk/androidTest/debug/app-debug-androidTest.apk")):
            local = root / "Android/app/build/outputs" / apk
            installed = subprocess.check_output([adb, "-s", serial, "shell", "pm", "path", package], text=True, timeout=15).strip()
            if re.fullmatch(r"package:/data/app/[A-Za-z0-9/._=+~-]+/base\.apk", installed):
                digest = subprocess.check_output([adb, "-s", serial, "shell", "sha256sum", installed.removeprefix("package:")], text=True, timeout=15).split()[0]
                if digest == hashlib.sha256(local.read_bytes()).hexdigest(): continue
            subprocess.run([adb, "-s", serial, "install", "-r", str(local)], check=True, timeout=180)
    for orientation, guide, guest in (("forward", args.guide, args.guest), ("reverse", args.guest, args.guide)):
        room = str(uuid.uuid4())
        processes, files = [], []
        try:
            for role, serial in (("guide", guide), ("guest", guest)):
                log = (artifacts / f"{orientation}-{role}.log").open("w"); files.append(log)
                processes.append(subprocess.Popen([adb, "-s", serial, "shell", "am", "instrument", "-w", "-r",
                    "-e", "class", "com.aessam.comeoverhere.BluetoothSpeedTest#measure", "-e", "speedRole", role,
                    "-e", "speedRoom", room, "-e", "speedBytes", "65536",
                    "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner"], stdout=log, stderr=subprocess.STDOUT))
            deadline = time.monotonic() + 240
            statuses = [p.wait(timeout=max(1, deadline - time.monotonic())) for p in processes]
            for file in files: file.flush()
            rows = []
            for role in ("guide", "guest"):
                content = (artifacts / f"{orientation}-{role}.log").read_text()
                if "OK (1 test)" not in content: raise RuntimeError(f"{orientation}/{role} failed: {artifacts}")
                for line in content.splitlines():
                    if line.startswith("INSTRUMENTATION_STATUS: bluetooth_speed="):
                        rows.append(json.loads(line.split("=", 1)[1]))
            if any(statuses) or len(rows) != 7: raise RuntimeError("Incomplete benchmark")
            (artifacts / f"{orientation}.json").write_text(json.dumps({"guide": guide, "guest": guest, "rows": rows}, indent=2))
            print(f"{orientation} PASS", flush=True)
        finally:
            for process in processes:
                if process.poll() is None: process.terminate(); process.wait(timeout=10)
            for file in files: file.close()


if __name__ == "__main__":
    main()
