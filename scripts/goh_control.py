#!/usr/bin/env python3
"""Run a command, watch state, or wait for a real app-state predicate over pinned TLS."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("credentials", type=Path)
    parser.add_argument("command")
    parser.add_argument("arguments", nargs="*")
    parser.add_argument("--cli", default=os.environ.get("GOH_CONTROL_CLI"))
    parser.add_argument("--field")
    parser.add_argument("--equals")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if not args.cli or not Path(args.cli).is_file():
        parser.error("Provide --cli or GOH_CONTROL_CLI pointing to the built goh-control executable")
    if not 0 < args.timeout <= 120:
        parser.error("Timeout must be in (0,120]")
    if args.command == "wait" and (not args.field or args.equals is None):
        parser.error("wait requires --field and --equals")
    deadline = time.monotonic() + args.timeout
    while True:
        command = "status" if args.command in ("wait", "watch") else args.command
        result = subprocess.run([args.cli, args.host, str(args.credentials / "control.key"), command, *args.arguments],
                                text=True, capture_output=True, timeout=12)
        if result.returncode:
            sys.stderr.write(result.stderr or result.stdout)
            return result.returncode
        state = json.loads(result.stdout)
        print(json.dumps(state, sort_keys=True), flush=True)
        if args.command not in ("wait", "watch"):
            return 0
        if args.command == "wait" and str(state.get(args.field, "")).lower() == args.equals.lower():
            return 0
        if time.monotonic() >= deadline:
            if args.command == "watch":
                return 0
            print("Timed out waiting for the requested app state", file=sys.stderr)
            return 1
        time.sleep(0.5)


if __name__ == "__main__":
    sys.exit(main())
