#!/usr/bin/env python3
"""Validate real native continuity recordings and adapt them to gateway runner evidence.

Four gates: complete recording, actual continuity checks, sampling coverage, and
verified app identity. Lock adds a fifth. This does not create acoustic/radio proof.
"""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import sys
import uuid

from verify_gateway_system import GateError, integer, read_json, require, sha256, write_json


def records(path):
    require(path.is_file() and 0 < path.stat().st_size <= 17 * 1024 * 1024, "native trace missing or oversized")
    values = []
    with path.open() as source:
        for line in source:
            require(len(line) <= 1024 * 1024 and len(values) <= 7205, "native trace exceeds bounds")
            value = json.loads(line)
            require(isinstance(value, dict), "native trace record must be an object")
            values.append(value)
    require(values and values[0].get("kind") == "header", "native trace lacks header")
    return values


def normalized(platform, trace, summary_path=None):
    values = records(trace)
    header = values[0]
    if platform == "ios":
        require(values[-1].get("kind") == "result", "iOS trace is unfinished/truncated")
        summary, samples = values[-1], values[1:-1]
        duration = header.get("durationSeconds")
        nonce = header.get("runID")
        require(summary.get("runID") == nonce, "iOS result belongs to a different recording")
        peer, build = header.get("deviceID"), str(header.get("bundleBuild"))
        timestamps = [sample.get("monotonicNanoseconds", -1) / 1_000_000 for sample in samples]
        same = [sample.get("sameRoom") for sample in samples]
        active = [sample.get("active") for sample in samples]
        snapshots = [sample.get("snapshot", {}) for sample in samples]
        completed = summary.get("status") == "continuity-checks-passed"
    else:
        require(summary_path is not None, "Android summary required")
        summary, samples = read_json(summary_path), values[1:]
        require(summary.get("id") == header.get("id"), "Android result belongs to a different recording")
        duration = header.get("duration_seconds")
        nonce = header.get("requested_run_id")
        require(summary.get("requested_run_id") == nonce, "Android requested run nonce mismatch")
        peer, build = header.get("device_id"), str(header.get("bundle_build"))
        timestamps = [sample.get("uptime_ms", -1) for sample in samples]
        same = [sample.get("same_room") for sample in samples]
        active = [sample.get("active") for sample in samples]
        snapshots = samples
        completed = summary.get("status") == "RECORDED_NOT_QUALIFIED"
    require(integer(duration, 1, 7200), "native duration invalid")
    require(samples and all(sample.get("kind") == "sample" for sample in samples), "native trace has zero samples or unexpected records")
    require(peer and nonce and all(type(value) is bool for value in [*same, *active]), "missing native identity or actual checks")
    uuid.UUID(nonce)
    require(all(type(value) in (int, float) and math.isfinite(value) and value >= 0 for value in timestamps), "invalid native monotonic timestamp")
    counts = summary.get("tests", {})
    require(all(integer(counts.get(key)) for key in ("executed", "passed", "failed", "skipped")), "invalid native test counts")
    actual_failed = sum(value is False for value in [*same, *active])
    require(counts["executed"] == len(samples) * 2 and counts["failed"] == actual_failed and counts["passed"] == len(samples) * 2 - actual_failed,
            "native actual test counts do not match retained samples")
    require(counts["skipped"] == 0, "native required checks were skipped")
    if platform == "android":
        require(summary.get("observed_samples") == len(samples), "Android observation count mismatch")
    return {"header": header, "duration": duration, "nonce": nonce, "peer": peer, "build": build,
            "timestamps": timestamps, "snapshots": snapshots, "completed": completed,
            "continuity": actual_failed == 0, "native_counts": counts}


def make_result(platform, trace, summary_path, probe, expected_nonce, minimum_seconds, scenario_id, locked=False, peer_map=None):
    value = normalized(platform, trace, summary_path)
    require(str(uuid.UUID(value["nonce"])) == str(uuid.UUID(expected_nonce)), "recording nonce is stale/not this requested run")
    require(probe.get("platform") == platform and probe.get("physical") is True, "external probe does not identify a physical device")
    verification = probe.get("artifact_verification", {})
    expected_method = "adb_sha256" if platform == "android" else "controlled_install_and_external_metadata"
    require(verification.get("verified") is True and verification.get("method") == expected_method, "missing external artifact verification")
    timestamps = value["timestamps"]
    gaps = [right - left for left, right in zip(timestamps, timestamps[1:])]
    coverage = value["duration"] >= minimum_seconds and len(timestamps) >= minimum_seconds
    coverage = coverage and all(0 < gap <= 1500 for gap in gaps)
    coverage = coverage and timestamps[-1] - timestamps[0] >= max(0, minimum_seconds - 1) * 1000
    identity = probe.get("app_snapshot", {})
    checks = {"recorder_complete": value["completed"], "session_continuity": value["continuity"],
              "sampling_coverage": coverage, "build_identity": value["peer"] == identity.get("deviceID") and value["build"] == str(identity.get("bundleBuild"))}
    lifecycle, routes = [], []
    peer_map = peer_map or {value["peer"]: probe["id"]}
    for snapshot in value["snapshots"]:
        debugger = snapshot.get("debuggerAttached") if platform == "ios" else snapshot.get("debugger_attached")
        awake = snapshot.get("debugKeepAwake") if platform == "ios" else snapshot.get("debug_keep_awake")
        # iOS `locked` means room-code lock, NOT screen lock. Never conflate them.
        screen_locked = snapshot.get("screenLocked") if platform == "ios" else snapshot.get("locked")
        if type(screen_locked) is bool:
            lifecycle.append({"device_id": probe["id"], "locked": screen_locked,
                              "debugger_attached": debugger, "debug_keep_awake": awake})
        for native in snapshot.get("routes", []):
            source, target = peer_map.get(native.get("fromDeviceID")), peer_map.get(native.get("toDeviceID"))
            if source and target and source != target:
                route = {"from": source, "to": target, "transport": native.get("transport"), "interface": native.get("interface"),
                         "connected": native.get("connected"), "fallback_used": native.get("fallbackUsed"),
                         "network_id": native.get("networkID"), "infrastructure_associated": native.get("infrastructureAssociated")}
                if route not in routes:
                    routes.append(route)
    if locked:
        checks["locked_without_debugger"] = len(lifecycle) == len(value["snapshots"]) and all(
            item["locked"] is True and item["debugger_attached"] is False and item["debug_keep_awake"] is False for item in lifecycle)
    passed = sum(checks.values())
    return {"schema": 1, "run_id": expected_nonce, "scenario_id": scenario_id, "device_id": probe["id"],
            "classification": "physical", "installed_sha256": probe["installed_sha256"],
            "tests": {"executed": len(checks), "passed": passed, "failed": len(checks) - passed, "skipped": 0},
            "assertions": {f"{probe['id']}.{key}": result for key, result in checks.items()}, "routes": routes, "lifecycle": lifecycle,
            "native_tests": value["native_counts"], "maximum_sample_gap_ms": max(gaps, default=0),
            "qualification_limit": "Per-sample app continuity only. No acoustic, capacity, RF medium, or thermal acceptance claim."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("ios", "android"))
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--verified-probe", type=Path)
    parser.add_argument("--minimum-seconds", required=True, type=int)
    parser.add_argument("--expected-run-id", default=os.environ.get("GOH_RUN_ID"))
    parser.add_argument("--scenario-id", default=os.environ.get("GOH_SCENARIO_ID"))
    parser.add_argument("--output", type=Path, default=os.environ.get("GOH_RESULT_PATH"))
    parser.add_argument("--locked", action="store_true")
    args = parser.parse_args(argv)
    try:
        probe_path = args.verified_probe
        if probe_path is None and os.environ.get("GOH_PREFLIGHT_DIR") and os.environ.get("GOH_DEVICE_ID"):
            probe_path = Path(os.environ["GOH_PREFLIGHT_DIR"]) / f"{os.environ['GOH_DEVICE_ID']}.json"
        require(probe_path and args.expected_run_id and args.scenario_id and args.output, "probe, run/scenario IDs and output are required")
        require(integer(args.minimum_seconds, 1, 7200), "minimum-seconds must be 1..7200")
        probe = read_json(probe_path)
        peer_map = {}
        if os.environ.get("GOH_PREFLIGHT_DIR"):
            for path in Path(os.environ["GOH_PREFLIGHT_DIR"]).glob("*.json"):
                candidate = read_json(path)
                identity = candidate.get("app_snapshot", {}).get("deviceID")
                if identity:
                    peer_map[identity] = candidate["id"]
        result = make_result(args.platform, args.trace, args.summary, probe, args.expected_run_id,
                             args.minimum_seconds, args.scenario_id, args.locked, peer_map)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        evidence_root = Path(os.environ.get("GOH_ATTEMPT_DIR", output.parent)).resolve()
        require(output.resolve().is_relative_to(evidence_root), "result path escapes attempt")
        require(not output.exists(), "result already exists; preserve prior evidence")
        evidence = []
        for index, source in enumerate([args.trace, probe_path, *([args.summary] if args.summary else [])]):
            destination = output.parent / f"{probe['id']}-native-{index}{source.suffix}"
            require(not destination.exists(), "native evidence destination already exists")
            shutil.copyfile(source, destination)
            evidence.append({"path": str(destination.resolve().relative_to(evidence_root)), "sha256": sha256(destination)})
        result["evidence"] = evidence
        write_json(output, result)
        print(json.dumps({"tests": result["tests"], "qualification_limit": result["qualification_limit"]}, indent=2))
        return 0 if result["tests"]["failed"] == 0 else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
