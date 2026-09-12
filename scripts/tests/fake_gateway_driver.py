#!/usr/bin/env python3
"""UNIT-TEST ONLY fake driver. Never use this for physical qualification."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time


def main():
    action = sys.argv[1]
    if action == "sleep":
        time.sleep(10)
        return
    if action == "probe":
        print(Path(sys.argv[2]).read_text())
        return
    if action == "cleanup":
        Path(sys.argv[2]).write_text("UNIT TEST CLEANUP\n")
        return
    device, checksum, mode = sys.argv[2:5]
    destination = Path(os.environ["GOH_RESULT_PATH"])
    evidence = destination.parent / (device + "-unit-evidence.txt")
    evidence.write_text("UNIT TEST FAKE DATA. NOT PHONE EVIDENCE.\n")
    passed, failed, skipped = 1, 0, 0
    if mode == "fail-once":
        marker = Path(sys.argv[5])
        if not marker.exists():
            marker.write_text("UNIT TEST ATTEMPT MARKER\n")
            passed, failed = 0, 1
    elif mode == "skip":
        passed, skipped = 0, 1
    elif mode == "zero":
        passed = 0
    elif mode == "missing":
        return
    result = {
        "schema": 1, "run_id": os.environ["GOH_RUN_ID"], "scenario_id": os.environ["GOH_SCENARIO_ID"],
        "device_id": device, "classification": "software", "installed_sha256": checksum,
        "tests": {"executed": passed + failed + skipped, "passed": passed, "failed": failed, "skipped": skipped},
        "assertions": {"unit_fixture_observed": True}, "routes": [],
        "evidence": [{"path": evidence.name, "sha256": hashlib.sha256(evidence.read_bytes()).hexdigest()}],
    }
    destination.write_text(json.dumps(result))


if __name__ == "__main__":
    main()
