#!/usr/bin/env python3
"""Manifest-driven gateway qualification. Commands are trusted argv, never shell text.

See gateway_tools.md for the native evidence contract. Dry-run validates only local
configuration; it never claims devices, audio, or physical routes passed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
MAX_LOG_BYTES = 32 * 1024 * 1024
ID = re.compile(r"^[A-Za-z0-9_.:-]{1,120}$")
HEX = re.compile(r"^[a-f0-9]{64}$")


class GateError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_sha256(path):
    """Canonical signed .app tree or single APK digest; no external symlink targets."""
    path = Path(path).resolve()
    if path.is_file():
        return sha256(path)
    require(path.is_dir() and path.suffix == ".app", "artifact must be a file or signed .app directory")
    digest = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        relative = str(item.relative_to(path)).encode()
        if item.is_symlink():
            require(item.resolve().is_relative_to(path), "app symlink escapes bundle")
            value = b"link\0" + os.readlink(item).encode()
        elif item.is_file():
            value = b"file\0" + sha256(item).encode()
        else:
            continue
        digest.update(len(relative).to_bytes(4, "big") + relative + len(value).to_bytes(4, "big") + value)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def read_json(path):
    require(Path(path).stat().st_size <= MAX_LOG_BYTES, f"JSON too large: {path}")
    with Path(path).open() as source:
        return json.load(source, parse_constant=lambda value: (_ for _ in ()).throw(GateError(f"Nonfinite JSON: {value}")))


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")
    temporary.replace(path)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def integer(value, minimum=0, maximum=1_000_000):
    return type(value) is int and minimum <= value <= maximum


def command_valid(command):
    require(isinstance(command, dict), "command must be an object")
    args = command.get("argv")
    require(isinstance(args, list) and args and all(isinstance(arg, str) and arg and "\0" not in arg for arg in args), "argv must contain nonempty strings")
    require(integer(command.get("timeout_s"), 1, 10800), "timeout_s must be 1..10800")


def safe_relative(root, name):
    require(isinstance(name, str) and name and not Path(name).is_absolute(), "evidence path must be relative")
    path = (root / name).resolve()
    require(path.is_relative_to(root.resolve()), f"evidence escapes attempt directory: {name}")
    return path


def validate_manifest(manifest, base):
    require(manifest.get("schema") == 1, "unsupported manifest schema")
    require(ID.fullmatch(manifest.get("name", "")), "invalid manifest name")
    require(integer(manifest.get("seed"), 0, 2**32 - 1), "seed must be explicit uint32")
    require(re.fullmatch(r"[a-f0-9]{40}", manifest.get("revision", "")), "revision must be an exact git revision")
    devices = manifest.get("devices")
    require(isinstance(devices, list) and len(devices) >= 3, "need guide, companion, and at least one listener")
    ids = [device.get("id", "") for device in devices]
    require(all(ID.fullmatch(value) for value in ids) and len(ids) == len(set(ids)), "invalid or duplicate device IDs")
    require(sum(device.get("role") == "guide" for device in devices) == 1, "exactly one guide required")
    require(sum(device.get("role") == "companion" for device in devices) == 1, "exactly one companion required")
    hubs = [device for device in devices if device.get("role") in ("guide", "companion")]
    require({device.get("platform") for device in hubs} == {"ios", "android"}, "hubs must span iOS and Android")
    for device in devices:
        require(device.get("role") in ("guide", "companion", "listener"), "invalid device role")
        require(device.get("platform") in ("ios", "android"), "invalid device platform")
        require(device.get("model") and device.get("os"), "pin expected device model and OS")
        artifact = device.get("artifact", {})
        require(HEX.fullmatch(artifact.get("sha256", "")), "artifact needs exact sha256")
        path = (base / artifact.get("path", "")).resolve()
        require(path.exists(), f"artifact missing: {path}")
        require(artifact_sha256(path) == artifact["sha256"], f"artifact hash mismatch: {path}")
        command_valid(device.get("probe"))
    scenarios = manifest.get("scenarios")
    require(isinstance(scenarios, list) and scenarios, "at least one scenario required")
    names = [scenario.get("id", "") for scenario in scenarios]
    require(all(ID.fullmatch(name) for name in names) and len(names) == len(set(names)), "invalid or duplicate scenario IDs")
    for scenario in scenarios:
        require(type(scenario.get("required")) is bool, "scenario required flag must be explicit")
        require(scenario.get("classification") in ("software", "physical"), "invalid scenario classification")
        require(type(scenario.get("requires_locked_listeners")) is bool, "declare lock requirement")
        tasks = scenario.get("tasks")
        require(isinstance(tasks, list) and tasks, "scenario has no tasks")
        task_ids = [task.get("id", "") for task in tasks]
        require(all(ID.fullmatch(value) for value in task_ids) and len(task_ids) == len(set(task_ids)), "invalid or duplicate task IDs")
        require(len({task.get("device_id") for task in tasks}) == len(tasks), "one scenario driver per device; do not run competing tasks on a phone")
        outputs = []
        for task in tasks:
            command_valid(task)
            require(task.get("device_id") in ids, "task device not in manifest")
            require(integer(task.get("expected_tests"), 1), "expected_tests must be positive")
            outputs.append(safe_relative(Path("/tmp/gateway-schema-check"), task.get("result")))
        require(len(outputs) == len(set(outputs)), "tasks must not share result files")
        required_assertions = scenario.get("required_assertions")
        require(isinstance(required_assertions, list) and required_assertions and all(isinstance(value, str) and value for value in required_assertions), "require explicit observable assertions")
        require(len(required_assertions) == len(set(required_assertions)), "duplicate required assertion")
        routes = scenario.get("required_routes", [])
        require(isinstance(routes, list), "required_routes must be an array")
        for route in routes:
            require(route.get("from") in ids and route.get("to") in ids and route["from"] != route["to"], "invalid route endpoints")
            require(route.get("transport") in ("usb", "android_aware", "apple_peer_to_peer"), "invalid strict transport")
        if scenario["classification"] == "physical":
            require(routes, "physical scenario must prove routes")
            require(scenario.get("cleanup"), "physical scenario requires explicit scoped cleanup commands")
        for cleanup in scenario.get("cleanup", []):
            command_valid(cleanup)
    require(any(scenario["required"] for scenario in scenarios), "no required scenarios")
    return manifest


def source_identity(root=ROOT):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, timeout=30)
    revision = git("rev-parse", "HEAD").decode().strip()
    dirty = git("status", "--porcelain", "-z")
    digest = hashlib.sha256(git("diff", "--binary", "HEAD"))
    digest.update(dirty)
    for name in sorted(git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")):
        if name:
            path = root / os.fsdecode(name)
            digest.update(name)
            if path.is_file():
                digest.update(sha256(path).encode())
    return {"revision": revision, "dirty": bool(dirty), "working_tree_sha256": digest.hexdigest()}


def terminate(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def execute(command, log_path, environment=None, cancel=None):
    """Bound process-group lifetime and log growth; retain stdout/stderr even on failure."""
    started = time.monotonic()
    with log_path.open("wb") as log:
        process = subprocess.Popen(command["argv"], cwd=ROOT, env={**os.environ, **(environment or {})},
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                if cancel and cancel.is_set():
                    raise GateError("command cancelled after another task failed")
                if time.monotonic() - started > command["timeout_s"]:
                    raise GateError(f"command timed out after {command['timeout_s']}s")
                if log_path.stat().st_size > MAX_LOG_BYTES:
                    raise GateError("command log exceeded 32 MiB")
                time.sleep(0.05)
            require(process.returncode == 0, f"command exited {process.returncode}; see {log_path.name}")
        finally:
            terminate(process)
    require(log_path.stat().st_size <= MAX_LOG_BYTES, "command log exceeded 32 MiB")
    return {"exit_code": process.returncode, "elapsed_s": round(time.monotonic() - started, 3)}


def device_lock(stack, device_id):
    key = hashlib.sha256(device_id.encode()).hexdigest()
    path = Path(tempfile.gettempdir()) / f"goh-gateway-device-{key}.lock"
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    handle = stack.enter_context(os.fdopen(descriptor, "r+"))
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        raise GateError(f"another gateway run owns device {device_id}") from error
    # Do not unlink: replacing an inode could bypass another process's held lock.


def validate_probe(device, value):
    for field in ("id", "platform", "model", "os"):
        require(value.get(field) == device[field], f"device {device['id']} {field} mismatch")
    require(value.get("installed_sha256") == device["artifact"]["sha256"], "installed artifact mismatch")
    verification = value.get("artifact_verification", {})
    allowed = ("adb_sha256",) if device["platform"] == "android" else ("controlled_install_and_external_metadata",)
    require(verification.get("method") in allowed and verification.get("verified") is True,
            "installed artifact needs external verification, not an app-reported hash")
    require(value.get("physical") is True, "a simulator/emulator is not a physical phone")
    require(value.get("session_state") == "idle", "device has an occupied tour; do not take over")
    require(value.get("wifi_enabled") is True, "Wi-Fi radio must remain enabled")
    require(value.get("debugger_attached") is False, "detach debugger before qualification")


def validate_task(result, task, scenario, manifest, attempt_dir, run_id):
    require(result.get("schema") == 1 and result.get("run_id") == run_id, "wrong result schema/run ID")
    require(result.get("scenario_id") == scenario["id"], "stale scenario result")
    require(result.get("device_id") == task["device_id"], "wrong result device")
    require(result.get("classification") == scenario["classification"], "scope inflation in result")
    device = next(value for value in manifest["devices"] if value["id"] == task["device_id"])
    require(result.get("installed_sha256") == device["artifact"]["sha256"], "result came from wrong build")
    counts = result.get("tests", {})
    require(all(integer(counts.get(key)) for key in ("executed", "passed", "failed", "skipped")), "invalid test counts")
    require(counts["executed"] == counts["passed"] + counts["failed"] + counts["skipped"], "inconsistent test counts")
    require(counts["executed"] == counts["passed"] == task["expected_tests"], "zero, missing, failed or skipped required tests")
    evidence = result.get("evidence")
    require(isinstance(evidence, list) and evidence, "result lacks raw evidence")
    for item in evidence:
        path = safe_relative(attempt_dir, item.get("path"))
        require(path.is_file() and path.stat().st_size > 0, "missing/empty raw evidence")
        require(item.get("sha256") == sha256(path), "raw evidence checksum mismatch")
    assertions = result.get("assertions")
    require(isinstance(assertions, dict) and assertions, "missing assertions")
    require(all(value is True for value in assertions.values()), "failed/nonboolean assertion")
    return result


def validate_scenario(results, scenario, manifest):
    assertions = {key for result in results for key, value in result["assertions"].items() if value is True}
    require(set(scenario["required_assertions"]).issubset(assertions), "required observable assertions missing")
    routes = [route for result in results for route in result.get("routes", [])]
    for expected in scenario.get("required_routes", []):
        matching = [route for route in routes if all(route.get(key) == value for key, value in expected.items())]
        require(matching, f"required route missing: {expected}")
        for route in matching:
            require(route.get("connected") is True and bool(route.get("interface")), "route is disconnected or interface unknown")
            require(route.get("fallback_used") is False, "fallback route cannot pass strict qualification")
            if route["transport"] == "android_aware":
                require(bool(route.get("network_id")), "Aware native Network ID missing")
            if route["transport"] == "apple_peer_to_peer":
                require(route.get("infrastructure_associated") is False, "Apple P2P qualification requires unassociated phones")
    if scenario["requires_locked_listeners"]:
        for device in manifest["devices"]:
            if device["role"] == "listener":
                observations = [item for result in results for item in result.get("lifecycle", []) if item.get("device_id") == device["id"]]
                require(observations, f"missing locked listener evidence: {device['id']}")
                require(all(item.get("locked") is True and item.get("debugger_attached") is False and item.get("debug_keep_awake") is False for item in observations), "debugger/keep-awake cannot qualify locked listeners")


def evidence_index(directory):
    require(not any(path.is_symlink() for path in directory.rglob("*")), "evidence bundle must not contain symlinks")
    return {str(path.relative_to(directory)): sha256(path) for path in sorted(directory.rglob("*"))
            if path.is_file() and path.name not in ("bundle.json", "report.json")}


def validate_bundle(directory):
    bundle = read_json(directory / "bundle.json")
    require(bundle.get("schema") == 1, "unsupported bundle schema")
    expected = bundle.get("files")
    require(isinstance(expected, dict) and expected, "bundle contains no evidence")
    require(expected == evidence_index(directory), "bundle file inventory/checksums changed")
    state = read_json(directory / "state.json")
    manifest = state["manifest"]
    for preflight in state.get("preflights", []):
        if preflight.get("status") == "PASS":
            probe_dir = safe_relative(directory, preflight["directory"])
            for device in manifest["devices"]:
                validate_probe(device, read_json(probe_dir / f"{device['id']}.json"))
    for attempt in state.get("attempts", []):
        require(attempt.get("status") in ("PASS", "FAIL"), "invalid attempt status")
        if attempt["status"] == "PASS":
            scenario = next(value for value in manifest["scenarios"] if value["id"] == attempt["scenario_id"])
            attempt_dir = safe_relative(directory, attempt["directory"])
            results = [validate_task(read_json(safe_relative(attempt_dir, task["result"])), task, scenario,
                                     manifest, attempt_dir, attempt["run_id"]) for task in scenario["tasks"]]
            validate_scenario(results, scenario, manifest)
    return bundle


def report(state):
    rows = []
    for scenario in state["manifest"]["scenarios"]:
        attempts = [value for value in state["attempts"] if value["scenario_id"] == scenario["id"]]
        latest = attempts[-1] if attempts else None
        rows.append({"scenario": scenario["id"], "required": scenario["required"],
                     "classification": scenario["classification"], "status": latest["status"] if latest else "NOT RUN",
                     "attempts": len(attempts), "earlier_failures": sum(value["status"] != "PASS" for value in attempts[:-1])})
    passed = all(row["status"] == "PASS" for row in rows if row["required"])
    return {"verdict": "PASS" if passed else "NOT QUALIFIED", "rows": rows,
            "warning": "Passing software scenarios does not establish physical qualification."}


def run_scenario(manifest, scenario, output, state):
    run_id = uuid.uuid4().hex
    attempt_dir = output / f"{len(state['attempts']) + 1:03d}-{scenario['id']}-{run_id[:8]}"
    attempt_dir.mkdir()
    attempt = {"scenario_id": scenario["id"], "run_id": run_id, "directory": attempt_dir.name,
               "started_at": utc_now(), "status": "FAIL", "errors": []}
    state["attempts"].append(attempt)
    write_json(output / "state.json", state)
    results = []
    cancel = threading.Event()

    def task_run(task):
        destination = safe_relative(attempt_dir, task["result"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        environment = {"GOH_RUN_ID": run_id, "GOH_SCENARIO_ID": scenario["id"], "GOH_SCENARIO_SEED": str(manifest["seed"]),
                       "GOH_RESULT_PATH": str(destination), "GOH_ATTEMPT_DIR": str(attempt_dir), "GOH_DEVICE_ID": task["device_id"],
                       "GOH_PREFLIGHT_DIR": str(output / state["preflights"][-1]["directory"])}
        execute(task, attempt_dir / f"{task['id']}.log", environment, cancel)
        require(destination.is_file(), f"driver did not produce {task['result']}")
        return validate_task(read_json(destination), task, scenario, manifest, attempt_dir, run_id)

    try:
        with ThreadPoolExecutor(max_workers=len(scenario["tasks"])) as pool:
            futures = [pool.submit(task_run, task) for task in scenario["tasks"]]
            try:
                for future in as_completed(futures):
                    try:
                        results.append(future.result())
                    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
                        cancel.set()
                        attempt["errors"].append(str(error))
            except BaseException:
                cancel.set()
                raise
        if not attempt["errors"]:
            validate_scenario(results, scenario, manifest)
    except (GateError, OSError, ValueError) as error:
        attempt["errors"].append(str(error))
    finally:
        for index, cleanup in enumerate(scenario.get("cleanup", [])):
            try:
                execute(cleanup, attempt_dir / f"cleanup-{index}.log", {"GOH_RUN_ID": run_id, "GOH_ATTEMPT_DIR": str(attempt_dir)})
            except (GateError, OSError, subprocess.SubprocessError) as error:
                attempt["errors"].append(f"cleanup failed: {error}")
        attempt["finished_at"] = utc_now()
        attempt["status"] = "FAIL" if attempt["errors"] else "PASS"
        write_json(output / "state.json", state)
    return attempt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, nargs="?")
    parser.add_argument("--mode", choices=("dry-run", "preflight", "run", "report", "collect"), default="dry-run")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--scenario", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        if args.mode in ("report", "collect"):
            require(args.output and args.output.is_dir(), "--output existing bundle required")
            validate_bundle(args.output)
            result = report(read_json(args.output / "state.json"))
            print(json.dumps(result, indent=2))
            return 0 if result["verdict"] == "PASS" else 1
        require(args.manifest and args.manifest.is_file(), "manifest required")
        manifest = validate_manifest(read_json(args.manifest), args.manifest.resolve().parent)
        source = source_identity()
        require(source["revision"] == manifest["revision"], "source revision differs from manifest")
        config_hash = hashlib.sha256(canonical({"manifest": manifest, "source": source})).hexdigest()
        selected = set(args.scenario)
        require(selected.issubset({value["id"] for value in manifest["scenarios"]}), "unknown selected scenario")
        if args.mode == "dry-run":
            print(json.dumps({"status": "CONFIGURATION VALIDATED ONLY", "config_sha256": config_hash,
                              "source": source, "physical_tests": "NOT RUN"}, indent=2))
            return 0
        require(args.output is not None, "--output required for retained evidence")
        output = args.output.resolve()
        require(not output.is_relative_to(ROOT), "evidence directory must be outside the source tree")
        if args.resume:
            validate_bundle(output)
            state = read_json(output / "state.json")
            require(state.get("config_sha256") == config_hash, "resume requires identical manifest, builds and source tree")
        else:
            require(not output.exists(), "output already exists; use --resume to preserve failed attempts")
            output.mkdir(parents=True)
            state = {"schema": 1, "manifest": manifest, "source": source, "config_sha256": config_hash,
                     "started_at": utc_now(), "attempts": [], "preflights": []}
        with ExitStack() as stack:
            for device in sorted(manifest["devices"], key=lambda value: value["id"]):
                device_lock(stack, device["id"])
            try:
                probe_dir = output / f"preflight-{len(state['preflights']) + 1:03d}"
                probe_dir.mkdir()
                preflight = {"started_at": utc_now(), "status": "FAIL", "directory": probe_dir.name, "errors": []}
                state["preflights"].append(preflight)
                for device in manifest["devices"]:
                    try:
                        log = probe_dir / f"{device['id']}.json"
                        execute(device["probe"], log)
                        validate_probe(device, read_json(log))
                    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
                        preflight["errors"].append(f"{device['id']}: {error}")
                require(not preflight["errors"], "; ".join(preflight["errors"]))
                preflight["status"] = "PASS"
                if args.mode == "run":
                    for scenario in manifest["scenarios"]:
                        if selected and scenario["id"] not in selected:
                            continue
                        previous = [value for value in state["attempts"] if value["scenario_id"] == scenario["id"]]
                        if args.resume and previous and previous[-1]["status"] == "PASS":
                            continue
                        attempt = run_scenario(manifest, scenario, output, state)
                        print(f"{scenario['id']}: {attempt['status']}", flush=True)
                        require(attempt["status"] == "PASS", "; ".join(attempt["errors"]))
            finally:
                write_json(output / "state.json", state)
                write_json(output / "report.json", report(state))
                write_json(output / "bundle.json", {"schema": 1, "files": evidence_index(output)})
        print(json.dumps(report(state), indent=2))
        return 0 if args.mode == "preflight" or report(state)["verdict"] == "PASS" else 1
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
