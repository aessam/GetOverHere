#!/usr/bin/env python3
"""Operate the real debug app through authorized ADB + pinned TLS + fresh HMAC.

First open GatewayDebugActivity and visibly Enable control. This tool never enables
it or installs/restarts the app. Credentials remain in memory and are not logged.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import socket
import ssl
import struct
import subprocess
import sys
import time
import uuid


PACKAGE = "com.aessam.comeoverhere"
MAX_FRAME = 32768


def adb_command(adb, device, arguments, *, sensitive=False, maximum=256 * 1024):
    result = subprocess.run([str(adb), "-s", device, *arguments], capture_output=True, timeout=15)
    if result.returncode:
        detail = "private credential retrieval failed; enable debug control visibly in the app" if sensitive else result.stderr.decode(errors="replace").strip()
        raise ValueError(f"ADB command failed ({result.returncode}): {detail}")
    if len(result.stdout) > maximum:
        raise ValueError("ADB reply exceeded bound")
    return result.stdout


def read_exact(connection, count):
    output = bytearray()
    while len(output) < count:
        data = connection.recv(count - len(output))
        if not data:
            raise ValueError("Debug connection closed before complete response")
        output.extend(data)
    return bytes(output)


def validate_credentials(value):
    if value.get("schema") != 1 or type(value.get("port")) is not int or not 1 <= value["port"] <= 65535:
        raise ValueError("invalid debug endpoint")
    key = base64.b64decode(value["key"], validate=True)
    pin = bytes.fromhex(value["certificate_sha256"])
    if len(key) != 32 or len(pin) != 32:
        raise ValueError("invalid debug key/pin length")
    if type(value.get("expires_at_ms")) is not int or value["expires_at_ms"] <= time.time() * 1000:
        raise ValueError("Debug activation expired; enable again visibly")
    return key, pin


def envelope(command, arguments, key, request_id=None):
    request_id = request_id or str(uuid.uuid4())
    uuid.UUID(request_id)
    if not isinstance(arguments, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in arguments.items()):
        raise ValueError("arguments must be a string-to-string object")
    payload = json.dumps({"id": request_id, "command": command, "arguments": arguments}, separators=(",", ":")).encode()
    encoded = json.dumps({"payload": base64.b64encode(payload).decode(),
                          "mac": base64.b64encode(hmac.digest(key, payload, "sha256")).decode()}, separators=(",", ":")).encode()
    if not 1 <= len(encoded) <= MAX_FRAME:
        raise ValueError("Debug request exceeds frame bound")
    return request_id, struct.pack(">I", len(encoded)) + encoded


def send(local_port, credentials, command, arguments):
    key, pin = validate_credentials(credentials)
    request_id, framed = envelope(command, arguments, key)
    # Verification is explicit complete-leaf pinning BEFORE sending any HMAC or
    # request. System PKI/hostname verification cannot validate a local self-signed identity.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    with socket.create_connection(("127.0.0.1", local_port), timeout=8) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as connection:
            certificate = connection.getpeercert(binary_form=True)
            if not hmac.compare_digest(hashlib.sha256(certificate).digest(), pin):
                raise ValueError("Debug TLS certificate pin mismatch; no request sent")
            connection.sendall(framed)
            length = struct.unpack(">I", read_exact(connection, 4))[0]
            if not 1 <= length <= MAX_FRAME:
                raise ValueError("Invalid debug response length")
            response = json.loads(read_exact(connection, length))
            if response.get("id", "").lower() != request_id.lower():
                raise ValueError("Mismatched debug response ID")
            if response.get("success") is not True:
                raise ValueError("App rejected command; check permissions, foreground and state")
            return json.loads(response["result"])


def control(adb, device, command, arguments):
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", device):
        raise ValueError("Invalid ADB device identifier")
    credentials = json.loads(adb_command(adb, device,
        ["exec-out", "run-as", PACKAGE, "cat", "files/debug-control/credentials.json"], sensitive=True))
    validate_credentials(credentials)
    port_text = adb_command(adb, device, ["forward", "tcp:0", f"tcp:{credentials['port']}"]).decode().strip()
    if not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
        raise ValueError("ADB did not return a valid forwarded port")
    try:
        result = send(int(port_text), credentials, command, arguments)
        result["_managementDeviceID"] = device
        return result
    finally:
        adb_command(adb, device, ["forward", "--remove", f"tcp:{port_text}"])


def export_scenario(adb, device, scenario_id, output):
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", device) or str(uuid.UUID(scenario_id)) != scenario_id:
        raise ValueError("Invalid device/scenario ID")
    if output.exists():
        raise ValueError("Export directory already exists; do not overwrite earlier evidence")
    output.mkdir(parents=True)
    hashes = {}
    for name in ("summary.json", "observations.jsonl"):
        payload = adb_command(adb, device, ["exec-out", "run-as", PACKAGE, "cat",
            f"files/debug-control/scenarios/{scenario_id}/{name}"], maximum=17 * 1024 * 1024)
        if not payload:
            raise ValueError("Empty scenario evidence")
        (output / name).write_bytes(payload)
        hashes[name] = hashlib.sha256(payload).hexdigest()
    summary = json.loads((output / "summary.json").read_text())
    if summary.get("id") != scenario_id:
        raise ValueError("Scenario result identity mismatch")
    (output / "export.json").write_text(json.dumps({"schema": 1, "device_id": device, "scenario_id": scenario_id,
        "files": hashes, "qualification": "NOT QUALIFIED: application observations only"}, indent=2) + "\n")
    return {"directory": str(output), "summary": summary, "sha256": hashes}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_id")
    parser.add_argument("command")
    parser.add_argument("--arguments-file", type=Path, help="JSON arguments; put room codes here, not command-line arguments")
    parser.add_argument("--arg", action="append", default=[], help="non-secret key=value argument")
    parser.add_argument("--scenario-id")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--adb", type=Path, default=Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")) / "platform-tools/adb")
    args = parser.parse_args(argv)
    try:
        if args.command == "export-scenario":
            if not args.scenario_id or not args.output:
                raise ValueError("export-scenario requires --scenario-id and --output")
            print(json.dumps(export_scenario(args.adb, args.device_id, args.scenario_id, args.output), indent=2))
            return 0
        arguments = json.loads(args.arguments_file.read_text()) if args.arguments_file else {}
        for value in args.arg:
            key, separator, text = value.partition("=")
            if not separator or not key or key in arguments or key.lower() in ("code", "key", "password", "token"):
                raise ValueError("Use unique non-secret key=value arguments; private values require --arguments-file")
            arguments[key] = text
        print(json.dumps(control(args.adb, args.device_id, args.command, arguments), indent=2))
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
