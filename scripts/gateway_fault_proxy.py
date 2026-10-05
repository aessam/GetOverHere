#!/usr/bin/env python3
"""Loopback-only framed-stream fault proxy for production transport integration tests.

Not a radio simulator or a qualification pass. Four-byte big-endian length framing
is preserved except for an explicitly requested malformed-length fault. Seeded
corruption never needs session keys; the receiving application must reject it.
"""
import argparse
import hashlib
import json
import random
import socket
import struct
import sys
import threading
import time


MAX_RECORD = 256 * 1024


def validate_plan(value):
    if value.get("schema") != 1 or type(value.get("seed")) is not int or not 0 <= value["seed"] < 2**32:
        raise ValueError("plan requires schema=1 and explicit uint32 seed")
    faults = value.get("faults")
    if not isinstance(faults, list) or not faults or len(faults) > 100:
        raise ValueError("provide 1..100 faults")
    seen = set()
    for fault in faults:
        if fault.get("direction") not in ("upstream", "downstream"):
            raise ValueError("invalid fault direction")
        if type(fault.get("record")) is not int or not 1 <= fault["record"] <= 1_000_000:
            raise ValueError("record number must be positive and bounded")
        key = (fault["direction"], fault["record"])
        if key in seen:
            raise ValueError("only one fault per direction/record")
        seen.add(key)
        if fault.get("operation") not in ("delay", "block", "eof", "corrupt", "duplicate", "malformed"):
            raise ValueError("unsupported fault operation")
        if fault["operation"] in ("delay", "block") and (
                type(fault.get("milliseconds")) is not int or not 1 <= fault["milliseconds"] <= 30_000):
            raise ValueError("delay/block must be 1..30000ms")
    return value


def transform(payload, fault, generator):
    """Pure record transform; zero-length ACK records remain legal."""
    encoded = struct.pack(">I", len(payload)) + payload
    if fault is None or fault["operation"] in ("delay", "block"):
        return [encoded]
    operation = fault["operation"]
    if operation == "eof":
        return []
    if operation == "duplicate":
        return [encoded, encoded]
    if operation == "malformed":
        return [struct.pack(">I", MAX_RECORD + 1) + payload]
    if operation == "corrupt":
        if not payload:
            raise ValueError("cannot corrupt empty ACK payload; choose a media record")
        altered = bytearray(payload)
        altered[generator.randrange(len(altered))] ^= 1 << generator.randrange(8)
        return [struct.pack(">I", len(altered)) + bytes(altered)]
    raise ValueError("unknown transform")


def read_exact(connection, count, deadline=None, stop=None):
    result = bytearray()
    while len(result) < count:
        if (stop and stop.is_set()) or (deadline and time.monotonic() >= deadline):
            raise ValueError("record read deadline exceeded/cancelled")
        try:
            part = connection.recv(count - len(result))
        except socket.timeout:
            if deadline is None:
                raise
            continue
        if not part:
            if result:
                raise ValueError("truncated record from source")
            return None
        result.extend(part)
    return bytes(result)


def serve_once(listener, target_port, plan, duration_s=30):
    """One bounded connection; returns observations, never PASS/quality assertions."""
    if not 1 <= duration_s <= 600:
        raise ValueError("session duration must be 1..600s")
    stop = threading.Event()
    events = []
    events_lock = threading.Lock()
    started = time.monotonic()
    deadline = started + duration_s
    listener.settimeout(min(duration_s, 10))
    downstream, _ = listener.accept()
    with downstream, socket.create_connection(("127.0.0.1", target_port), timeout=5) as upstream:
        downstream.settimeout(1)
        upstream.settimeout(1)

        def pump(source, destination, direction):
            generator = random.Random(f"{plan['seed']}:{direction}")
            record = 0
            try:
                while not stop.is_set() and time.monotonic() < deadline:
                    header = read_exact(source, 4, deadline, stop)
                    if header is None:
                        destination.shutdown(socket.SHUT_WR)
                        return
                    size = struct.unpack(">I", header)[0]
                    if size > MAX_RECORD:
                        raise ValueError("incoming record exceeds 256KiB")
                    payload = read_exact(source, size, deadline, stop)
                    if payload is None:
                        raise ValueError("source closed within framed record")
                    record += 1
                    fault = next((value for value in plan["faults"] if value["direction"] == direction and value["record"] == record), None)
                    if fault and fault["operation"] in ("delay", "block"):
                        stop.wait(min(fault["milliseconds"] / 1000, max(0, deadline - time.monotonic())))
                    if stop.is_set() or time.monotonic() >= deadline:
                        return
                    outputs = transform(payload, fault, generator)
                    for output in outputs:
                        destination.sendall(output)
                    with events_lock:
                        events.append({"direction": direction, "record": record, "operation": fault["operation"] if fault else "forward",
                                       "source_sha256": hashlib.sha256(payload).hexdigest(), "output_records": len(outputs),
                                       "elapsed_ms": round((time.monotonic() - started) * 1000, 3)})
                    if fault and fault["operation"] == "eof":
                        destination.shutdown(socket.SHUT_WR)
                        return
            except (OSError, ValueError) as error:
                with events_lock:
                    events.append({"direction": direction, "error": str(error)})
                stop.set()

        workers = [threading.Thread(target=pump, args=(downstream, upstream, "upstream")),
                   threading.Thread(target=pump, args=(upstream, downstream, "downstream"))]
        try:
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(timeout=max(0, deadline - time.monotonic()))
        finally:
            stop.set()
            for connection in (upstream, downstream):
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError as error:
                    with events_lock:
                        events.append({"cleanup": str(error)})
            for worker in workers:
                worker.join(timeout=2)
            if any(worker.is_alive() for worker in workers):
                raise RuntimeError("fault proxy worker did not stop")
    return {"schema": 1, "scope": "loopback_framed_fault_injection_only", "seed": plan["seed"], "events": events}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan")
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--listen-port", default=0, type=int)
    parser.add_argument("--duration-s", default=30, type=int)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if not 1 <= args.target_port <= 65535 or not 0 <= args.listen_port <= 65535:
            raise ValueError("invalid port")
        with open(args.plan) as source:
            plan = validate_plan(json.load(source))
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", args.listen_port))
            listener.listen(1)
            print(json.dumps({"listen": listener.getsockname(), "scope": "loopback_only"}), flush=True)
            result = serve_once(listener, args.target_port, plan, args.duration_s)
        with open(args.output, "w") as destination:
            json.dump(result, destination, indent=2)
            destination.write("\n")
        errors = [value for value in result["events"] if "error" in value]
        return 1 if errors else 0
    except (OSError, ValueError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
