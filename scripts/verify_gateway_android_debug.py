#!/usr/bin/env python3
"""Emulator-only TLS/HMAC debug-adapter component gate; never a radio/audio field test."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from verify_gateway_system import GateError, device_lock, require, sha256, write_json


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="emulator-5554")
    parser.add_argument("--adb", type=Path, default=Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")) / "platform-tools/adb")
    parser.add_argument("--app-apk", type=Path, default=Path("Android/app/build/outputs/apk/debug/app-debug.apk"))
    parser.add_argument("--test-apk", type=Path, default=Path("Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"))
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        require(re.fullmatch(r"emulator-[0-9]+", args.device), "this component runner refuses physical phones")
        require(not args.output.exists(), "output exists; preserve prior results")
        require(args.app_apk.is_file() and args.test_apk.is_file(), "built app and instrumentation APKs required")
        args.output.mkdir(parents=True)
        base = [str(args.adb), "-s", args.device]

        def command(arguments, timeout=30):
            result = subprocess.run([*base, *arguments], capture_output=True, text=True, timeout=timeout)
            require(result.returncode == 0, f"ADB failed: {result.stderr or result.stdout}")
            return result.stdout

        with ExitStack() as stack:
            device_lock(stack, args.device)
            require(command(["get-state"]).strip() == "device", "emulator not ready")
            require(command(["shell", "getprop", "ro.kernel.qemu"]).strip() == "1", "not an emulator")
            hashes = {}
            for package, path in (("com.aessam.comeoverhere", args.app_apk), ("com.aessam.comeoverhere.test", args.test_apk)):
                if args.install:
                    require("Success" in command(["install", "-r", str(path)], timeout=120), "APK install did not succeed")
                remote = command(["shell", "pm", "path", package]).strip()
                require(remote.startswith("package:/") and "\n" not in remote, "single installed APK required")
                hashes[package] = sha256(path)
                require(command(["shell", "sha256sum", remote[len("package:"):]]).split()[0] == hashes[package], "installed APK differs; rebuild/install selected artifacts")
            write_json(args.output / "manifest.json", {"schema": 1, "device": args.device, "scope": "emulator_debug_adapter_only", "apk_sha256": hashes})
            arguments = ["shell", "am", "instrument", "-w", "-r", "-e", "class", "com.aessam.comeoverhere.GatewayDebugControlTest",
                         "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner"]
            try:
                result = subprocess.run([*base, *arguments], capture_output=True, text=True, timeout=90)
                text = result.stdout + result.stderr
                (args.output / "instrumentation.log").write_text(text)
                require(result.returncode == 0 and re.search(r"OK \(5 tests\)", text), "expected exactly five passing instrumentation tests")
                require("INSTRUMENTATION_FAILED" not in text and "FAILURES!!!" not in text and "INSTRUMENTATION_STATUS_CODE: -3" not in text, "instrumentation failed/skipped")
            except subprocess.TimeoutExpired as error:
                (args.output / "instrumentation.log").write_bytes((error.stdout or b"") + (error.stderr or b""))
                command(["shell", "am", "force-stop", "com.aessam.comeoverhere"])
                raise GateError("bounded debug component timeout; test app stopped") from error
            write_json(args.output / "result.json", {"executed": 5, "passed": 5, "failed": 0, "skipped": 0,
                                                     "scope": "emulator_debug_adapter_only", "log_sha256": sha256(args.output / "instrumentation.log")})
        print(f"PASS: 5/5 actual emulator TLS/HMAC debug-adapter tests; {args.output}")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
