#!/usr/bin/env python3
"""Opt-in real-app network smoke. Starts capture and attempts cleanup of its own room."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("credentials", type=Path)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--create-room", action="store_true", required=True)
    parser.add_argument("--ui-device")
    parser.add_argument("--ui-manifest", type=Path)
    parser.add_argument("--ui-results", type=Path)
    args = parser.parse_args()
    if not args.cli.is_file() or not (args.credentials / "control.key").is_file():
        parser.error("Build the CLI and create private credentials first")
    ui_options = (args.ui_device, args.ui_manifest, args.ui_results)
    if any(ui_options) and not all(ui_options):
        parser.error("Provide all three --ui-device/--ui-manifest/--ui-results options")
    if args.ui_results:
        if not args.ui_manifest.is_file() or args.ui_results.exists():
            parser.error("UI manifest must exist and UI results directory must be new")
        args.ui_results.mkdir(parents=True)

    def observe(screen):
        if args.ui_device:
            subprocess.run([sys.executable, str(Path(__file__).with_name("observe_iphone_debug_control.py")),
                            args.ui_device, str(args.ui_manifest), "--screen", screen,
                            "--result", str(args.ui_results / f"{screen}.xcresult")], check=True)

    def command(action, **values):
        result = subprocess.run([str(args.cli), args.host, str(args.credentials / "control.key"), action,
                                 *[f"{key}={value}" for key, value in values.items()]],
                                capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError(f"{action} failed: {result.stderr or result.stdout}")
        state = json.loads(result.stdout)
        print(json.dumps({"command": action, "state": state}, sort_keys=True), flush=True)
        return state

    def wait(field, expected):
        deadline = time.monotonic() + 20
        while True:
            state = command("status")
            if state.get(field) == expected:
                return state
            if state.get("error") or time.monotonic() >= deadline:
                raise RuntimeError(f"Expected {field}={expected}; current state is in the run log")
            time.sleep(0.5)

    initial = command("status")
    if initial["activeRoom"] or not initial["foreground"]:
        raise RuntimeError("Preflight requires a foreground app with no active room")
    command("show-debug")
    wait("screen", "debug")
    observe("debug")
    command("dismiss")
    command("show-create")
    wait("screen", "create")
    command("dismiss")
    owned_room = ""
    try:
        state = command("create", name="Debug control smoke")
        owned_room = state["activeRoom"]
        state = wait("audio", "running")
        owned_room = state["activeRoom"]
        if not owned_room or state["role"] != "guide":
            raise RuntimeError("Creation did not reach a guide room")
        for feature in ("map", "pointer", "slides"):
            command("feature", name=feature)
            wait("feature", feature)
            if feature == "pointer":
                observe("pointer")
        # Public throwaway fixture code, never a user's credential.
        command("room-lock", locked="true", code="debug-smoke-4829")
        wait("locked", True)
        command("room-lock", locked="false")
        wait("locked", False)
    finally:
        if owned_room:
            current = command("status")
            if current["activeRoom"] != owned_room:
                raise RuntimeError("Room ownership changed; refusing to end someone else's room")
            command("leave")
            wait("activeRoom", "")
            wait("audio", "idle")
            command("discovery", bluetooth=str(initial["bluetooth"]).lower(), aware=str(initial["aware"]).lower())
    print("PASS: real-app create/audio/navigation/lock/unlock/leave over authenticated TLS")


if __name__ == "__main__":
    main()
