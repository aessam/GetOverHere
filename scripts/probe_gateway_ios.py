#!/usr/bin/env python3
"""Controlled iOS install receipts and read-only qualification probes via public devicectl.

Install is opt-in, requires an idle real-app status command first, and never starts
debugging or changes network/radio settings. Probe mode never installs/relaunches.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

from verify_gateway_system import GateError, artifact_sha256, command_valid, read_json, require, sha256, write_json


def devicectl(arguments, timeout=30):
    command = ["/usr/bin/xcrun", "devicectl", *arguments, "--timeout", str(timeout), "--json-output", "-"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 5)
    require(result.returncode == 0, f"devicectl failed: {result.stderr[-2000:]}")
    value = json.loads(result.stdout)
    require(value.get("info", {}).get("outcome") == "success", "devicectl did not report success")
    return value


def app_metadata(app):
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == "com.aens.GetOverHere", "unexpected bundle identifier")
    require(bool(info.get("CFBundleVersion")), "missing bundle build")
    return {"bundle_id": info["CFBundleIdentifier"], "bundle_build": str(info["CFBundleVersion"]),
            "bundle_version": str(info.get("CFBundleShortVersionString", ""))}


def app_snapshot(command_path):
    command = read_json(command_path)
    command_valid(command)
    # Only status: no mutations or argument forwarding in a preflight adapter.
    require("status" in command["argv"] or "gateway-status" in command["argv"], "status command must explicitly request status")
    result = subprocess.run(command["argv"], capture_output=True, text=True, timeout=command["timeout_s"])
    require(result.returncode == 0, "authenticated iOS status command failed; credentials are not logged")
    require(len(result.stdout) <= 32768, "status response too large")
    snapshot = json.loads(result.stdout)
    require(bool(snapshot.get("deviceID")) and snapshot.get("sessionState") in ("idle", "active"), "status lacks authoritative app identity/state")
    return snapshot


def external_identity(device):
    result = devicectl(["device", "info", "details", "--device", device])["result"]
    # These are documented legacy categories still emitted by devicectl. If Apple
    # removes them, fail with retained raw JSON rather than guessing new fields.
    hardware, software = result.get("hardwareProperties", {}), result.get("deviceProperties", {})
    require(hardware.get("platform") == "iOS" and hardware.get("udid") == device,
            "select an exact physical UDID; metadata is absent or does not match")
    require(hardware.get("marketingName") and software.get("osVersionNumber"), "device metadata schema changed")
    return {"id": device, "platform": "ios", "model": hardware["marketingName"], "os": software["osVersionNumber"], "raw": result}


def installed_metadata(device, expected):
    raw = devicectl(["device", "info", "apps", "--device", device, "--bundle-id", expected["bundle_id"]])
    apps = raw.get("result", {}).get("apps", [])
    matches = [app for app in apps if app.get("bundleIdentifier") == expected["bundle_id"]]
    require(len(matches) == 1, "installed app missing or ambiguous")
    app = matches[0]
    require(str(app.get("bundleVersion", "")) == expected["bundle_build"], "installed bundle build differs")
    return raw


def copy_app_file(device, source, destination):
    require(not source.startswith("/") and ".." not in Path(source).parts, "app file source must remain within app container")
    return devicectl(["device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
                     "--domain-identifier", "com.aens.GetOverHere", "--source", source, "--destination", str(destination)], timeout=30)


def bind_snapshot_to_device(device, snapshot):
    with tempfile.TemporaryDirectory(prefix="GetOverHereIOSProbe-") as directory:
        endpoint = Path(directory) / "endpoint.json"
        copy_app_file(device, "Library/Caches/DebugControl/endpoint.json", endpoint)
        observation = read_json(endpoint)
    require(observation.get("deviceID") == snapshot["deviceID"], "network debug endpoint is not this physical device's app instance")
    return observation


def install_receipt(device, app, command_path, output):
    require(not output.exists(), "receipt directory already exists; do not overwrite")
    snapshot = app_snapshot(command_path)
    require(snapshot["sessionState"] == "idle", "device has an active tour; install refused")
    identity = external_identity(device)
    endpoint = bind_snapshot_to_device(device, snapshot)
    metadata = app_metadata(app)
    digest = artifact_sha256(app)
    output.mkdir(parents=True)
    write_json(output / "before.json", {"device": identity, "snapshot": snapshot, "endpoint": endpoint})
    installed = devicectl(["device", "install", "app", "--device", device, str(app.resolve())], timeout=120)
    write_json(output / "install.json", installed)
    observed = installed_metadata(device, metadata)
    write_json(output / "installed-app.json", observed)
    receipt = {"schema": 1, "device_id": device, "app_peer_id": snapshot["deviceID"], "artifact_sha256": digest,
               **metadata, "installed_at": datetime.now(timezone.utc).isoformat(),
               "method": "controlled_install_and_external_metadata", "verified": True,
               "evidence": {name: sha256(output / name) for name in ("before.json", "install.json", "installed-app.json")}}
    write_json(output / "receipt.json", receipt)
    return receipt


def validate_receipt(path, device, app):
    receipt = read_json(path)
    require(receipt.get("schema") == 1 and receipt.get("device_id") == device and receipt.get("verified") is True, "receipt identity invalid")
    require(receipt.get("method") == "controlled_install_and_external_metadata", "unsupported receipt method")
    require(receipt.get("artifact_sha256") == artifact_sha256(app), "selected .app differs from installed receipt")
    metadata = app_metadata(app)
    require(all(receipt.get(key) == value for key, value in metadata.items()), "receipt metadata mismatch")
    require(set(receipt.get("evidence", {})) == {"before.json", "install.json", "installed-app.json"}, "receipt is missing raw installation evidence")
    for name, checksum in receipt["evidence"].items():
        require(sha256(path.parent / name) == checksum, "installation evidence changed")
    require(read_json(path.parent / "install.json").get("info", {}).get("outcome") == "success", "installation was not successful")
    return receipt


def probe(device, app, receipt_path, command_path, radio_path):
    receipt = validate_receipt(receipt_path, device, app)
    identity = external_identity(device)
    installed = installed_metadata(device, app_metadata(app))
    snapshot = app_snapshot(command_path)
    endpoint = bind_snapshot_to_device(device, snapshot)
    require(str(snapshot.get("bundleBuild")) == receipt["bundle_build"], "debug app build mismatch")
    radio = read_json(radio_path)
    require(radio.get("device_id") == device and radio.get("wifi_enabled") is True, "missing explicit Wi-Fi radio observation")
    require(radio.get("source") in ("operator_settings_observation", "device_settings_capture"), "unknown radio observation source")
    timestamp = datetime.fromisoformat(radio["observed_at"]).timestamp()
    require(0 <= time.time() - timestamp <= 600, "radio observation is older than ten minutes or future-dated")
    require(type(snapshot.get("debuggerAttached")) is bool, "debugger state unavailable")
    return {"id": device, "platform": "ios", "model": identity["model"], "os": identity["os"], "physical": True,
            "installed_sha256": receipt["artifact_sha256"], "session_state": snapshot["sessionState"],
            "wifi_enabled": True, "debugger_attached": snapshot["debuggerAttached"], "app_snapshot": snapshot,
            "artifact_verification": {"method": receipt["method"], "verified": True, "receipt_sha256": sha256(receipt_path),
                                      "limitation": "controlled install plus external build metadata; not a readback hash of installed iOS bundle"},
            "radio_observation": radio, "device_metadata": identity["raw"], "installed_metadata": installed, "endpoint_binding": endpoint}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_id")
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--status-command", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--radio-observation", type=Path)
    parser.add_argument("--install-and-record", type=Path, metavar="NEW_RECEIPT_DIRECTORY", help="Explicitly authorize installing the selected app after idle checks")
    args = parser.parse_args(argv)
    try:
        if args.install_and_record:
            result = install_receipt(args.device_id, args.app, args.status_command, args.install_and_record)
        else:
            require(args.receipt and args.radio_observation, "read-only probe requires --receipt and --radio-observation")
            result = probe(args.device_id, args.app, args.receipt, args.status_command, args.radio_observation)
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
