#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DEVELOPER_DIR="${GOH_XCODE_DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo /Users/aessam/Downloads/Xcode-beta.app/Contents/Developer)}"
XCRUN="${GOH_XCRUN:-/usr/bin/xcrun}"
ADB="${GOH_ADB:-/Users/aessam/Library/Android/sdk/platform-tools/adb}"
IOS_BUNDLE_ID="${GOH_IOS_BUNDLE_ID:-com.aens.GetOverHere}"
RUN_ROOT="${GOH_PHYSICAL_RUN_ROOT:-/tmp/GetOverHerePhysicalRuns}"

usage() {
    cat <<'USAGE'
Usage:
  scripts/capture_physical_test.sh start [--ios-device ID] [--android-serial ID] [--run-dir PATH]
  scripts/capture_physical_test.sh mark --run-dir PATH --label TEXT
  scripts/capture_physical_test.sh status --run-dir PATH
  scripts/capture_physical_test.sh stop --run-dir PATH

Environment overrides:
  GOH_XCODE_DEVELOPER_DIR  Xcode developer directory
  GOH_XCRUN                xcrun executable
  GOH_ADB                  adb executable
  GOH_IOS_BUNDLE_ID        iOS app bundle identifier
  GOH_PHYSICAL_RUN_ROOT    default parent for run directories

The harness never clears device logs, restarts an existing app, collects a
sysdiagnose, or writes raw physical-device output inside the repository.
USAGE
}

fail() {
    echo "error: $*" >&2
    exit 1
}

require_executable() {
    local path="$1"
    local label="$2"
    if [[ "$path" == */* ]]; then
        [[ -x "$path" ]] || fail "$label is not executable at $path"
    else
        command -v "$path" >/dev/null 2>&1 || fail "$label is not available: $path"
    fi
}

validate_run_directory() {
    [[ -n "$RUN_DIR" ]] || fail "--run-dir is required"
    [[ "$RUN_DIR" == /* ]] || fail "run directory must be an absolute path"
    [[ "$RUN_DIR" != "/" ]] || fail "run directory cannot be /"
    case "$RUN_DIR/" in
        "$PROJECT_ROOT"/*) fail "raw physical logs must stay outside the repository" ;;
    esac
}

parse_arguments() {
    IOS_DEVICE="${GOH_IOS_DEVICE:-}"
    ANDROID_SERIAL="${GOH_ANDROID_SERIAL:-}"
    RUN_DIR=""
    MARK_LABEL=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ios-device)
                [[ $# -ge 2 ]] || fail "--ios-device requires a value"
                IOS_DEVICE="$2"
                shift 2
                ;;
            --android-serial)
                [[ $# -ge 2 ]] || fail "--android-serial requires a value"
                ANDROID_SERIAL="$2"
                shift 2
                ;;
            --run-dir)
                [[ $# -ge 2 ]] || fail "--run-dir requires a value"
                RUN_DIR="$2"
                shift 2
                ;;
            --label)
                [[ $# -ge 2 ]] || fail "--label requires a value"
                MARK_LABEL="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) fail "unknown argument: $1" ;;
        esac
    done
}

preflight_ios() {
    [[ -n "$IOS_DEVICE" ]] || return 0
    require_executable "$XCRUN" "xcrun"
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
        "$XCRUN" devicectl device info details \
        --device "$IOS_DEVICE" \
        --timeout 20 \
        --json-output /dev/null \
        --log-output /dev/null >/dev/null
}

preflight_android() {
    [[ -n "$ANDROID_SERIAL" ]] || return 0
    require_executable "$ADB" "adb"
    local state
    state="$($ADB -s "$ANDROID_SERIAL" get-state 2>/dev/null)" || fail "Android device $ANDROID_SERIAL is unavailable"
    [[ "$state" == "device" ]] || fail "Android device $ANDROID_SERIAL state is $state"
    "$ADB" -s "$ANDROID_SERIAL" shell true >/dev/null
}

write_manifest() {
    {
        echo "schema=GetOverHerePhysicalRun/v1"
        echo "started_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "git_commit=$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
        echo "ios_device=${IOS_DEVICE:-none}"
        echo "android_serial=${ANDROID_SERIAL:-none}"
        echo "ios_bundle_id=$IOS_BUNDLE_ID"
        echo "xcode_developer_dir=$XCODE_DEVELOPER_DIR"
        echo "raw_logs_must_not_be_committed=true"
    } >"$RUN_DIR/manifest.txt"
}

snapshot_ios() {
    local suffix="$1"
    [[ -n "$IOS_DEVICE" ]] || return 0
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
        "$XCRUN" devicectl device info details \
        --device "$IOS_DEVICE" \
        --timeout 20 \
        --json-output "$RUN_DIR/ios/device-$suffix.json" \
        --log-output "$RUN_DIR/ios/devicectl-$suffix.log" >/dev/null
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
        "$XCRUN" devicectl device info processes \
        --device "$IOS_DEVICE" \
        --search GetOverHere \
        --timeout 20 \
        --json-output "$RUN_DIR/ios/processes-$suffix.json" \
        --log-output "$RUN_DIR/ios/devicectl-processes-$suffix.log" >/dev/null
}

snapshot_android() {
    local suffix="$1"
    [[ -n "$ANDROID_SERIAL" ]] || return 0
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys battery >"$RUN_DIR/android/battery-$suffix.txt"
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys thermalservice >"$RUN_DIR/android/thermal-$suffix.txt"
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys connectivity >"$RUN_DIR/android/connectivity-$suffix.txt"
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys wifi >"$RUN_DIR/android/wifi-$suffix.txt"
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys wifiaware >"$RUN_DIR/android/wifiaware-$suffix.txt"
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys bluetooth_manager >"$RUN_DIR/android/bluetooth-$suffix.txt"
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys audio >"$RUN_DIR/android/audio-$suffix.txt"
}

snapshot_all() {
    local suffix="$1"
    snapshot_ios "$suffix"
    snapshot_android "$suffix"
}

start_ios_console() {
    [[ -n "$IOS_DEVICE" ]] || return 0
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
        "$XCRUN" devicectl device process launch \
        --device "$IOS_DEVICE" \
        --console \
        --timeout 86400 \
        --log-output "$RUN_DIR/ios/devicectl-console.log" \
        "$IOS_BUNDLE_ID" >"$RUN_DIR/ios/app-console.txt" 2>&1 &
    echo "$!" >"$RUN_DIR/ios/console.pid"
}

start_android_logcat() {
    [[ -n "$ANDROID_SERIAL" ]] || return 0
    "$ADB" -s "$ANDROID_SERIAL" logcat -b all -v threadtime -T 1 \
        >"$RUN_DIR/android/logcat.txt" 2>"$RUN_DIR/android/logcat-error.txt" &
    echo "$!" >"$RUN_DIR/android/logcat.pid"
}

read_pid() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    local pid
    pid="$(<"$path")"
    [[ "$pid" =~ ^[0-9]+$ ]] || fail "invalid PID file: $path"
    echo "$pid"
}

report_pid() {
    local label="$1"
    local path="$2"
    local pid
    if ! pid="$(read_pid "$path")"; then
        echo "$label=not-started"
    elif kill -0 "$pid" 2>/dev/null; then
        echo "$label=running pid=$pid"
    else
        echo "$label=stopped pid=$pid"
    fi
}

stop_pid() {
    local label="$1"
    local path="$2"
    local pid
    if ! pid="$(read_pid "$path")"; then
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" || fail "could not stop $label process $pid"
    fi
}

start_run() {
    if [[ -z "$RUN_DIR" ]]; then
        RUN_DIR="$RUN_ROOT/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    fi
    validate_run_directory
    [[ -n "$IOS_DEVICE" || -n "$ANDROID_SERIAL" ]] || fail "provide at least one physical device"
    [[ ! -e "$RUN_DIR" ]] || fail "run directory already exists: $RUN_DIR"

    preflight_ios
    preflight_android
    mkdir -p "$RUN_DIR/ios" "$RUN_DIR/android"
    write_manifest
    snapshot_all start
    start_ios_console
    start_android_logcat

    echo "run_dir=$RUN_DIR"
    report_pid "ios_console" "$RUN_DIR/ios/console.pid"
    report_pid "android_logcat" "$RUN_DIR/android/logcat.pid"
}

mark_run() {
    validate_run_directory
    [[ -d "$RUN_DIR" ]] || fail "run directory does not exist: $RUN_DIR"
    [[ -n "$MARK_LABEL" ]] || fail "--label is required"
    [[ "$MARK_LABEL" != *$'\n'* && "$MARK_LABEL" != *$'\t'* ]] || fail "marker label cannot contain tabs or newlines"
    printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$MARK_LABEL" >>"$RUN_DIR/markers.tsv"
}

status_run() {
    validate_run_directory
    [[ -d "$RUN_DIR" ]] || fail "run directory does not exist: $RUN_DIR"
    report_pid "ios_console" "$RUN_DIR/ios/console.pid"
    report_pid "android_logcat" "$RUN_DIR/android/logcat.pid"
}

stop_run() {
    validate_run_directory
    [[ -d "$RUN_DIR" ]] || fail "run directory does not exist: $RUN_DIR"
    [[ -f "$RUN_DIR/manifest.txt" ]] || fail "run manifest is missing: $RUN_DIR/manifest.txt"

    IOS_DEVICE="$(sed -n 's/^ios_device=//p' "$RUN_DIR/manifest.txt")"
    ANDROID_SERIAL="$(sed -n 's/^android_serial=//p' "$RUN_DIR/manifest.txt")"
    [[ "$IOS_DEVICE" != "none" ]] || IOS_DEVICE=""
    [[ "$ANDROID_SERIAL" != "none" ]] || ANDROID_SERIAL=""

    local snapshot_status=0
    snapshot_all stop || snapshot_status=$?
    stop_pid "iOS console" "$RUN_DIR/ios/console.pid"
    stop_pid "Android logcat" "$RUN_DIR/android/logcat.pid"
    echo "stopped_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$RUN_DIR/manifest.txt"
    echo "stop_signals_sent=true"
    [[ "$snapshot_status" -eq 0 ]] || fail "end-state snapshot failed with status $snapshot_status"
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || { usage; exit 1; }
shift
parse_arguments "$@"

case "$COMMAND" in
    start) start_run ;;
    mark) mark_run ;;
    status) status_run ;;
    stop) stop_run ;;
    -h|--help|help) usage ;;
    *) fail "unknown command: $COMMAND" ;;
esac
