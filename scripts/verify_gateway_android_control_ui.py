#!/usr/bin/env python3
"""Emulator-only visible consent → authenticated client → actual tour/recorder smoke.

No physical phones. Requires installed current Debug APK and microphone permission.
Leaves the test room and disables its endpoint; retained recorder evidence is not
acoustic or physical transport qualification.
"""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

from gateway_android_control import control, export_scenario
from verify_gateway_system import GateError, device_lock, require, write_json


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="emulator-5554")
    parser.add_argument("--adb", type=Path, default=Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--grant-microphone", action="store_true", help="Emulator only: grant missing microphone permission and restore its prior state afterward")
    args = parser.parse_args(argv)
    if args.adb.is_dir():
        args.adb = args.adb / "platform-tools/adb"
    try:
        require(re.fullmatch(r"emulator-[0-9]+", args.device), "UI component smoke refuses physical phones")
        require(not args.output.exists(), "output exists; preserve previous run")
        args.output.mkdir(parents=True)
        base = [str(args.adb), "-s", args.device]

        def command(arguments):
            result = subprocess.run([*base, *arguments], capture_output=True, text=True, timeout=20)
            require(result.returncode == 0, result.stderr or result.stdout)
            return result.stdout

        def tap(label):
            dumped = command(["shell", "uiautomator", "dump", "/sdcard/goh-debug-consent.xml"])
            (args.output / "hierarchy-export.log").write_text(dumped)
            require("UI hierchary dumped" in dumped or "UI hierarchy dumped" in dumped, f"UI hierarchy export failed: {dumped}")
            xml = command(["shell", "cat", "/sdcard/goh-debug-consent.xml"])
            (args.output / ("consent-enable.xml" if label.startswith("Enable") else "consent-disable.xml")).write_text(xml)
            nodes = [node for node in ET.fromstring(xml).iter("node")
                     if node.get("text", "").casefold() == label.casefold()
                     and node.get("package") == "com.aessam.comeoverhere"]
            require(len(nodes) == 1 and nodes[0].get("enabled") == "true", f"visible enabled button not found: {label}")
            coordinates = [int(number) for number in re.findall(r"\d+", nodes[0].get("bounds", ""))]
            require(len(coordinates) == 4, "invalid UI bounds")
            x1, y1, x2, y2 = coordinates
            command(["shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2)])

        with ExitStack() as stack:
            device_lock(stack, args.device)
            require(command(["shell", "getprop", "ro.kernel.qemu"]).strip() == "1", "not an emulator")
            # Never alter permission state for an existing controller's session.
            exists = subprocess.run([*base, "shell", "run-as", "com.aessam.comeoverhere", "test", "-f", "files/debug-control/credentials.json"], capture_output=True, timeout=10)
            require(exists.returncode != 0, "debug endpoint already active; finish that work first")
            permissions = command(["shell", "dumpsys", "package", "com.aessam.comeoverhere"])
            microphone = re.search(r"android\.permission\.RECORD_AUDIO: granted=(true|false)", permissions)
            require(microphone is not None, "microphone permission state unavailable")
            if microphone[1] == "false":
                require(args.grant_microphone, "emulator microphone permission missing; use explicit --grant-microphone")
                command(["shell", "pm", "grant", "com.aessam.comeoverhere", "android.permission.RECORD_AUDIO"])
                stack.callback(command, ["shell", "pm", "revoke", "com.aessam.comeoverhere", "android.permission.RECORD_AUDIO"])
            command(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            command(["shell", "wm", "dismiss-keyguard"])
            command(["shell", "am", "start", "-W", "-n", "com.aessam.comeoverhere/.debug.GatewayDebugActivity"])
            started_room = False
            try:
                tap("Enable debug control for 10 minutes")
                deadline = time.monotonic() + 12
                while True:
                    try:
                        before = control(args.adb, args.device, "status", {})
                        break
                    except (OSError, ValueError, subprocess.SubprocessError):
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(.25)
                write_json(args.output / "before.json", before)
                require(before["sessionState"] == "idle", "existing tour is occupied")
                started_room = True
                control(args.adb, args.device, "create", {"name": "Gateway UI smoke " + uuid.uuid4().hex[:6]})
                deadline = time.monotonic() + 10
                while True:
                    state = control(args.adb, args.device, "status", {})
                    if state.get("audio") == "RUNNING" and state.get("role") == "guide":
                        break
                    require(time.monotonic() < deadline, "actual guide capture did not start")
                    time.sleep(.25)
                require(state["deviceID"] == before["deviceID"], "app was unexpectedly replaced")
                write_json(args.output / "active.json", state)
                nonce = str(uuid.uuid4())
                recording = control(args.adb, args.device, "scenario-start", {"seconds": "10", "runID": nonce})
                deadline = time.monotonic() + 18
                while True:
                    state = control(args.adb, args.device, "scenario-status", {})
                    if state.get("active") is False:
                        break
                    require(time.monotonic() < deadline, "bounded native recording did not finish")
                    time.sleep(.5)
                exported = export_scenario(args.adb, args.device, recording["id"], args.output / "native")
                summary = exported["summary"]
                require(summary.get("requested_run_id") == nonce and summary.get("observed_samples", 0) >= 10, "native recorder did not retain requested run/samples")
                counts = summary.get("tests", {})
                require(counts.get("executed", 0) > 0 and counts.get("passed") == counts.get("executed") and counts.get("failed") == counts.get("skipped") == 0,
                        "native continuity checks failed")
                write_json(args.output / "native-checks.json", counts)
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                write_json(args.output / "failure.json", {"error": str(error)})
                raise
            finally:
                cleanup_errors = []
                if started_room:
                    for action in ("scenario-cancel", "leave"):
                        try:
                            control(args.adb, args.device, action, {})
                        except (OSError, ValueError, subprocess.SubprocessError) as error:
                            cleanup_errors.append(f"{action}: {error}")
                try:
                    tap("Disable debug control")
                    command(["shell", "rm", "/sdcard/goh-debug-consent.xml"])
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    cleanup_errors.append(f"endpoint/UI cleanup: {error}")
                write_json(args.output / "cleanup.json", {"errors": cleanup_errors})
                require(not cleanup_errors, "; ".join(cleanup_errors))
            write_json(args.output / "result.json", {"scope": "emulator_actual_UI_client_and_recorder_only", "status": "PASS", "native_tests": counts,
                                                     "qualification": "No physical USB, Aware, Apple peer or acoustic claim"})
        print(f"PASS: visible consent, live TLS/HMAC Python client, actual guide capture and native recording; {args.output}")
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
