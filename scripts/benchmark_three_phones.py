#!/usr/bin/env python3
"""Sequential three-phone matrix; never run competing radio experiments on a phone."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios", required=True)
    parser.add_argument("--android", nargs=2, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    artifacts = Path(tempfile.mkdtemp(prefix="GetOverHereThreePhones.", dir="/tmp"))
    print(f"Matrix: {artifacts}", flush=True)
    trials = [(f"{serial}-{role}", [serial], role) for serial in args.android for role in ("guide", "guest")]
    trials.append(("two-listeners", args.android, "guide"))
    outcomes = []
    for name, peers, role in trials:
        command = [sys.executable, str(root / "benchmark_bluetooth_pair.py"), "--ios", args.ios,
            "--android", *peers, "--manifest", str(args.manifest), "--ios-role", role, "--bytes", "65536"]
        print(f"Starting {name}", flush=True)
        with (artifacts / f"{name}.log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=450)
        outcomes.append({"name": name, "exit_code": result.returncode, "log": str(artifacts / f"{name}.log")})
        (artifacts / "outcomes.json").write_text(json.dumps(outcomes, indent=2))
        print(f"{name}: {'PASS' if result.returncode == 0 else 'FAIL'}", flush=True)
        if result.returncode:
            raise RuntimeError(f"Matrix stopped at failed trial; preserve failure and inspect {artifacts}")
    print(f"Completed Bluetooth matrix: {artifacts}", flush=True)


if __name__ == "__main__":
    main()
