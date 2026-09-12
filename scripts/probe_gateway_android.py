#!/usr/bin/env python3
"""Read-only physical Android inventory and installed-APK verification over ADB.

Without --status-command this is inventory only, never a qualification preflight.
The status command must call the real app's authenticated debug status interface.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from verify_gateway_system import GateError, command_valid, require, sha256


def query(argv, timeout=15):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    require(result.returncode == 0, f"command failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    require(len(result.stdout) < 4 * 1024 * 1024, "unexpectedly large device reply")
    return result.stdout.strip()


def probe(adb, device_id, artifact=None, package="com.aessam.comeoverhere", status_command=None):
    require(re.fullmatch(r"[A-Za-z0-9_.:-]+", device_id), "invalid ADB device identifier")
    require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]+", package), "invalid package name")
    device = [str(adb), "-s", device_id]
    require(query([*device, "get-state"]) == "device", "device not ready")
    physical = query([*device, "shell", "getprop", "ro.kernel.qemu"]) != "1" and not device_id.startswith("emulator-")
    value = {
        "id": device_id, "platform": "android", "physical": physical,
        "model": query([*device, "shell", "getprop", "ro.product.model"]),
        "os": query([*device, "shell", "getprop", "ro.build.version.release"]),
        "api": query([*device, "shell", "getprop", "ro.build.version.sdk"]),
        "wifi_enabled": query([*device, "shell", "settings", "get", "global", "wifi_on"]) == "1",
        "interfaces": query([*device, "shell", "ip", "-brief", "address"]),
        "scope": "read_only_inventory",
    }
    if artifact:
        packages = query([*device, "shell", "pm", "path", package]).splitlines()
        require(len(packages) == 1 and packages[0].startswith("package:/"), "single APK installation required; split APK hash matching is not implemented")
        remote_path = packages[0][len("package:"):]
        require(re.fullmatch(r"/[A-Za-z0-9_./=+~\-]+", remote_path), "unexpected installed APK path")
        checksum = query([*device, "shell", "sha256sum", remote_path]).split()[0]
        require(checksum == sha256(artifact), "installed APK differs from selected local artifact")
        value.update(installed_sha256=checksum, artifact_verification={"method": "adb_sha256", "verified": True})
    if status_command:
        require(artifact is not None, "qualification preflight requires --artifact")
        command_valid(status_command)
        snapshot = json.loads(query(status_command["argv"], status_command["timeout_s"]))
        require(snapshot.get("_managementDeviceID") == device_id, "debug status was not read through the selected device's ADB tunnel")
        require(bool(snapshot.get("deviceID")), "debug status lacks application peer identity")
        require(snapshot.get("sessionState") in ("idle", "active"), "debug status lacks authoritative sessionState")
        require(type(snapshot.get("debuggerAttached")) is bool, "debug status lacks debuggerAttached")
        value.update(session_state=snapshot["sessionState"], debugger_attached=snapshot["debuggerAttached"],
                     scope="read_only_qualification_preflight", app_snapshot=snapshot)
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_id")
    parser.add_argument("--adb", type=Path, default=Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")) / "platform-tools/adb")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--package", default="com.aessam.comeoverhere")
    parser.add_argument("--status-command", type=Path, help="JSON object with argv and timeout_s; read-only authenticated status")
    args = parser.parse_args(argv)
    try:
        command = json.loads(args.status_command.read_text()) if args.status_command else None
        print(json.dumps(probe(args.adb, args.device_id, args.artifact, args.package, command), indent=2))
        return 0
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
