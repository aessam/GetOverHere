#!/usr/bin/env python3
"""Read-only export of one explicitly named iOS debug recording via devicectl."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import uuid

from gateway_recorder_result import records
from probe_gateway_ios import copy_app_file
from verify_gateway_system import require, sha256, write_json


def export(device, run_id, output):
    canonical_id = str(uuid.UUID(run_id)).upper()
    require(not output.exists(), "export directory exists; preserve earlier evidence")
    output.mkdir(parents=True)
    destination = output / "observations.jsonl"
    receipt = copy_app_file(device, f"Library/Caches/GatewayRuns/{canonical_id}.jsonl", destination)
    values = records(destination)
    require(str(uuid.UUID(values[0].get("runID", ""))).upper() == canonical_id, "recording does not match requested run")
    write_json(output / "copy-receipt.json", receipt)
    result = {"schema": 1, "device_id": device, "run_id": canonical_id,
              "files": {name: sha256(output / name) for name in ("observations.jsonl", "copy-receipt.json")},
              "qualification": "NOT QUALIFIED: export only; validate counts, cadence and identity with gateway_recorder_result.py"}
    write_json(output / "export.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_id")
    parser.add_argument("run_id")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        print(json.dumps(export(args.device_id, args.run_id, args.output), indent=2))
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
