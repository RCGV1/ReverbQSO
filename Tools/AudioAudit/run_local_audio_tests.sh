#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODE=${1:-quick}
DESTINATION=${REVERB_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}
DERIVED_DATA=${REVERB_DERIVED_DATA:-/tmp/reverb-audio-build}
ITERATIONS=${REVERB_AUDIO_ITERATIONS:-1}

case "$MODE" in
    quick|stress|full) ;;
    *) printf 'Usage: %s [quick|stress|full]\n' "$0" >&2; exit 2 ;;
esac
case "$ITERATIONS" in
    ''|*[!0-9]*|0) printf 'REVERB_AUDIO_ITERATIONS must be a positive integer\n' >&2; exit 2 ;;
esac

OUT=${REVERB_AUDIO_RESULTS:-$(mktemp -d /tmp/reverb-local-audio.XXXXXX)}
mkdir -p "$OUT"
if [[ -e "$OUT/tests.xcresult" || -e "$OUT/xcodebuild.log" ]]; then
    printf 'Choose an unused REVERB_AUDIO_RESULTS directory: %s\n' "$OUT" >&2
    exit 2
fi

# Never inherit opt-ins that enable real stations, microphones, or hardware I/O.
for flag in ECHOLINK_RUN_AUDIO_AUDIT ECHOLINK_RUN_LOCAL_SPEEX_AUDIT \
    ECHOLINK_RUN_LIVE_TESTS ECHOLINK_RUN_QSO_REFRESH_AUDIT \
    ECHOLINK_RUN_RELOAD_AUDIT ECHOLINK_RUN_STATION_AUDIT; do
    export "$flag=0" "TEST_RUNNER_$flag=0"
done

ARGS=(-project "$ROOT/ReverbQSO.xcodeproj" -scheme ReverbQSO
    -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA"
    -resultBundlePath "$OUT/tests.xcresult" CODE_SIGNING_ALLOWED=NO
    -parallel-testing-enabled NO -test-iterations "$ITERATIONS"
    -test-timeouts-enabled YES -default-test-execution-time-allowance 90
    -maximum-test-execution-time-allowance 180
    -skip-testing:ReverbQSOTests/LiveTransportSmokeTests
    -skip-testing:ReverbQSOTests/LiveAudioRoundTripTests)

if [[ "$MODE" != full ]]; then
    SUITES=(AudioEngineOfflineTests SimulatedSvxLinkCodecMatrixTests
        RemoteVoiceActivityTests SpeexTransmitConnectionTests
        SpeexBitrateCompatibilityTests SpeexBitrateLocalPeerTests
        GSMCodecStreamingTests SpeexCodecTests SpeexReceiveStreamDecoderTests
        EchoLinkAudioPacketCodecTests SpeexTransmitNegotiationTests
        VoicePipelineQualityTests PCMLinearResamplerTests NativeCapturePCMTests
        CaptureDSPProcessorTests VoiceTransmitQueueTests)
    if [[ "$MODE" == stress ]]; then
        SUITES+=(SvxLinkImpairmentAuditTests ReceiveAudioSoakTests
            SvxLinkLocalPeerTests ConferenceReceiveAudioCodecTests
            EchoLinkAudioReorderBufferTests ReceiveSpeechSmootherTests
            ReceiveNativeSpeechSmootherTests ReceiveAdaptivePlayoutBufferTests
            ReceiveClockRecoveryTests ReceivePlaybackQueueTests)
    fi
    for suite in "${SUITES[@]}"; do
        ARGS+=("-only-testing:ReverbQSOTests/$suite")
    done
fi

printf 'Local audio gate: %s (%s iteration(s))\nResults: %s\n' "$MODE" "$ITERATIONS" "$OUT"
STATUS=0
xcodebuild "${ARGS[@]}" test 2>&1 | tee "$OUT/xcodebuild.log" || STATUS=$?
if [[ -d "$OUT/tests.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$OUT/tests.xcresult" --compact || true
fi
exit "$STATUS"
