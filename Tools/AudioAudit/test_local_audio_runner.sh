#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/reverb-audio-runner-tests.XXXXXX")
trap 'rm -r "$WORK"' EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }
contains_line() {
    local line
    while IFS= read -r line; do
        if [[ "$line" == "$2" ]]; then return 0; fi
    done < "$1"
    return 1
}
require_line() { contains_line "$1" "$2" || fail "Missing argument: $2"; }

# The exported function prevents these argument tests from invoking real Xcode.
xcodebuild() {
    printf '%s\n' "$@" > "$CAPTURE_ARGS"
    local flag prefixed
    for flag in ECHOLINK_RUN_AUDIO_AUDIT ECHOLINK_RUN_LOCAL_SPEEX_AUDIT \
        ECHOLINK_RUN_LIVE_TESTS ECHOLINK_RUN_QSO_REFRESH_AUDIT \
        ECHOLINK_RUN_RELOAD_AUDIT ECHOLINK_RUN_STATION_AUDIT; do
        prefixed="TEST_RUNNER_$flag"
        printf '%s=%s\n' "$flag" "${!flag}" "$prefixed" "${!prefixed}"
    done > "$CAPTURE_ENV"
    return "$FAKE_XCODE_STATUS"
}
export -f xcodebuild

run_case() (
    local name=$1 configuration=$2 mode=$3 iterations=$4 expected=$5 actual=0
    export CAPTURE_ARGS="$WORK/$name.args" CAPTURE_ENV="$WORK/$name.env"
    export REVERB_AUDIO_RESULTS="$WORK/$name.results" REVERB_AUDIO_ITERATIONS="$iterations"
    export FAKE_XCODE_STATUS=${6:-0}
    if [[ -n "$configuration" ]]; then export REVERB_TEST_CONFIGURATION="$configuration"
    else unset REVERB_TEST_CONFIGURATION; fi
    local flag
    for flag in ECHOLINK_RUN_AUDIO_AUDIT ECHOLINK_RUN_LOCAL_SPEEX_AUDIT \
        ECHOLINK_RUN_LIVE_TESTS ECHOLINK_RUN_QSO_REFRESH_AUDIT \
        ECHOLINK_RUN_RELOAD_AUDIT ECHOLINK_RUN_STATION_AUDIT; do
        export "$flag=1" "TEST_RUNNER_$flag=1"
    done
    bash "$ROOT/Tools/AudioAudit/run_local_audio_tests.sh" "$mode" > "$WORK/$name.log" 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] || fail "$name: exit $actual, expected $expected"
)

run_case debug "" quick 1 0
require_line "$WORK/debug.args" Debug
if contains_line "$WORK/debug.args" ENABLE_TESTABILITY=YES; then fail "Debug defaults were overridden"; fi

run_case release Release stress 3 0
require_line "$WORK/release.args" Release
require_line "$WORK/release.args" ENABLE_TESTABILITY=YES
require_line "$WORK/release.args" ONLY_ACTIVE_ARCH=YES
require_line "$WORK/release.args" 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) REVERB_TESTING'
require_line "$WORK/release.args" -test-iterations
require_line "$WORK/release.args" 3
require_line "$WORK/release.args" -only-testing:ReverbQSOTests/ReceiveAudioSoakTests
require_line "$WORK/release.args" -skip-testing:ReverbQSOTests/LiveTransportSmokeTests
require_line "$WORK/release.args" -skip-testing:ReverbQSOTests/LiveAudioRoundTripTests
for name in debug release; do
    count=0
    while IFS= read -r line; do
        [[ "$line" == *=0 ]] || fail "$name inherited a live/hardware opt-in"
        count=$((count + 1))
    done < "$WORK/$name.env"
    [[ "$count" == 12 ]] || fail "$name did not clear all opt-ins"
done

run_case full Release full 1 0
while IFS= read -r line; do
    [[ "$line" != -only-testing:* ]] || fail "Full mode was narrowed"
done < "$WORK/full.args"

run_case bad-config Beta quick 1 2
run_case bad-iterations Debug quick 0 2
run_case bad-mode Debug invalid 1 2
for name in bad-config bad-iterations bad-mode; do
    [[ ! -e "$WORK/$name.args" ]] || fail "$name invoked Xcode"
done
run_case failure Debug quick 1 7 7
printf 'Local audio runner: 7 cases passed; no Xcode or hardware invoked.\n'
