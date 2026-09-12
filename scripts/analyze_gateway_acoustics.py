#!/usr/bin/env python3
"""Cross-correlate reference/output channels from ONE simultaneous PCM WAV recording.

This is external acoustic evidence, never RTT/2. Use distinct, broadband reference
markers; repeated tones and direct acoustic leakage can produce ambiguous peaks.
No microphone capture is started by this tool. PCM 16/24/32-bit WAV only.
"""
import argparse
import cmath
import hashlib
import json
import math
from pathlib import Path
import sys
import wave


def fft(values, inverse=False):
    """Iterative radix-2 transform, avoiding a host NumPy dependency."""
    values = list(values)
    size = len(values)
    if size == 0 or size & (size - 1):
        raise ValueError("FFT length must be a positive power of two")
    target = 0
    for index in range(1, size):
        bit = size >> 1
        while target & bit:
            target ^= bit
            bit >>= 1
        target ^= bit
        if index < target:
            values[index], values[target] = values[target], values[index]
    width = 2
    while width <= size:
        root = cmath.exp((2j if inverse else -2j) * math.pi / width)
        for offset in range(0, size, width):
            weight = 1
            for index in range(offset, offset + width // 2):
                even, odd = values[index], values[index + width // 2] * weight
                values[index], values[index + width // 2] = even + odd, even - odd
                weight *= root
        width *= 2
    return [value / size for value in values] if inverse else values


def correlation(reference, received):
    """Return normalized, mean-removed cross-correlation at all valid offsets."""
    if len(reference) < 8 or len(received) < len(reference):
        raise ValueError("reference must have >=8 samples and fit inside received window")
    if not all(math.isfinite(value) for value in [*reference, *received]):
        raise ValueError("samples must be finite")
    count = len(reference)
    mean = sum(reference) / count
    centered = [value - mean for value in reference]
    reference_energy = sum(value * value for value in centered)
    if reference_energy <= 1e-12:
        raise ValueError("silent/constant reference window")
    size = 1
    while size < len(received) + count - 1:
        size <<= 1
    left = fft([*reversed(centered), *([0] * (size - count))])
    right = fft([*received, *([0] * (size - len(received)))])
    products = fft([a * b for a, b in zip(left, right)], inverse=True)
    sums, squares = [0.0], [0.0]
    for value in received:
        sums.append(sums[-1] + value)
        squares.append(squares[-1] + value * value)
    result = []
    for offset in range(len(received) - count + 1):
        total = sums[offset + count] - sums[offset]
        energy = max(0.0, squares[offset + count] - squares[offset] - total * total / count)
        score = products[offset + count - 1].real / math.sqrt(reference_energy * energy) if energy > 1e-12 else 0.0
        result.append(max(-1.0, min(1.0, score)))
    return result


def percentile(values, quantile):
    if not values or not 0 < quantile <= 1 or not all(math.isfinite(value) for value in values):
        raise ValueError("percentile requires finite samples and quantile in (0,1]")
    return sorted(values)[math.ceil(len(values) * quantile) - 1]


def match_delay(reference, received, sample_rate, minimum_score=0.5, ambiguity_ratio=0.9):
    scores = correlation(reference, received)
    peak = max(range(len(scores)), key=lambda index: abs(scores[index]))
    best = abs(scores[peak])
    # Adjacent samples describe the same peak; independently repeated peaks do not.
    exclusion = max(1, round(sample_rate * 0.005))
    alternatives = [abs(value) for index, value in enumerate(scores) if abs(index - peak) > exclusion]
    runner_up = max(alternatives, default=0.0)
    if best < minimum_score:
        raise ValueError(f"weak correlation: {best:.3f} < {minimum_score:.3f}")
    if runner_up >= best * ambiguity_ratio:
        raise ValueError(f"ambiguous correlation: best={best:.3f}, independent peak={runner_up:.3f}")
    return {"delay_ms": peak * 1000 / sample_rate, "correlation": scores[peak], "second_peak": runner_up}


def read_channel(source, start_frame, frame_count, channel):
    if not 0 <= channel < source.getnchannels():
        raise ValueError("channel outside WAV layout")
    if start_frame < 0 or start_frame + frame_count > source.getnframes():
        raise ValueError("analysis window extends beyond recording")
    source.setpos(start_frame)
    raw = source.readframes(frame_count)
    width, channels = source.getsampwidth(), source.getnchannels()
    if width not in (2, 3, 4) or source.getcomptype() != "NONE":
        raise ValueError("only uncompressed signed PCM 16/24/32-bit WAV is supported")
    scale = float(1 << (width * 8 - 1))
    stride = width * channels
    return [int.from_bytes(raw[index + channel * width:index + (channel + 1) * width], "little", signed=True) / scale
            for index in range(0, len(raw), stride)]


def analyze(path, reference_channel, listener_channels, starts_s, window_ms=200, maximum_delay_ms=600):
    if not starts_s or any(not math.isfinite(value) or value < 0 for value in starts_s):
        raise ValueError("provide nonnegative reference window start times")
    if not 20 <= window_ms <= 1000 or not 1 <= maximum_delay_ms <= 2000:
        raise ValueError("window must be 20..1000ms and maximum delay 1..2000ms")
    if not listener_channels or reference_channel in listener_channels or len(set(listener_channels)) != len(listener_channels):
        raise ValueError("choose distinct reference and listener channels")
    rows, failures = [], []
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        if not 8000 <= rate <= 192000:
            raise ValueError("unsupported sample rate")
        count = round(rate * window_ms / 1000)
        search = round(rate * maximum_delay_ms / 1000)
        metadata = {"sample_rate": rate, "channels": source.getnchannels(), "sample_width": source.getsampwidth(),
                    "duration_s": source.getnframes() / rate}
        for start_s in starts_s:
            start = round(start_s * rate)
            reference = read_channel(source, start, count, reference_channel)
            for channel in listener_channels:
                received = read_channel(source, start, count + search, channel)
                try:
                    result = match_delay(reference, received, rate)
                    rows.append({"reference_start_s": start_s, "listener_channel": channel, **result})
                except ValueError as error:
                    failures.append({"reference_start_s": start_s, "listener_channel": channel, "error": str(error)})
    summaries = []
    for channel in listener_channels:
        delays = [row["delay_ms"] for row in rows if row["listener_channel"] == channel]
        summaries.append({"listener_channel": channel, "valid_windows": len(delays), "expected_windows": len(starts_s),
                          "p50_ms": percentile(delays, .5) if delays else None,
                          "p95_ms": percentile(delays, .95) if delays else None,
                          "p99_ms": percentile(delays, .99) if delays else None})
    skews = []
    if len(listener_channels) > 1:
        for start in starts_s:
            delays = [row["delay_ms"] for row in rows if row["reference_start_s"] == start]
            if len(delays) == len(listener_channels):
                skews.append(max(delays) - min(delays))
    digest = hashlib.sha256()
    with Path(path).open("rb") as recording:
        for chunk in iter(lambda: recording.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"schema": 1, "measurement": "simultaneous_external_reference_cross_correlation", "input_sha256": digest.hexdigest(),
            "recording": metadata, "reference_channel": reference_channel, "window_ms": window_ms,
            "maximum_delay_ms": maximum_delay_ms, "rows": rows, "failures": failures, "listeners": summaries,
            "skew_p95_ms": percentile(skews, .95) if skews else None,
            "status": "VALID_MEASUREMENT" if not failures else "INCOMPLETE_MEASUREMENT",
            "limits": "Selected windows only; not a continuity/loss or field qualification pass. Check reference isolation and recording geometry."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--reference-channel", type=int, required=True)
    parser.add_argument("--listener-channel", type=int, action="append", required=True)
    parser.add_argument("--start-s", type=float, action="append", required=True)
    parser.add_argument("--window-ms", type=int, default=200)
    parser.add_argument("--maximum-delay-ms", type=int, default=600)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        result = analyze(args.recording, args.reference_channel, args.listener_channel, args.start_s,
                         args.window_ms, args.maximum_delay_ms)
        payload = json.dumps(result, indent=2, allow_nan=False) + "\n"
        if args.output:
            args.output.write_text(payload)
        print(payload, end="")
        return 0 if result["status"] == "VALID_MEASUREMENT" else 1
    except (ValueError, OSError, wave.Error) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
