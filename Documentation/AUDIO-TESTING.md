# Audio Validation And Device Readiness

## Codec Scope

| Format | Receive | Transmit | Simulated Peer |
| --- | --- | --- | --- |
| GSM 06.10 | Yes | Yes, fallback | SvxLink-style |
| Speex narrowband 15 kbps | Yes | Yes, after SPEEX capability | SvxLink-style |
| Speex narrowband 18.2 / 24.6 kbps | Yes | Experimental offline encoder only | SvxLink-style receive validation |
| G.711 PCMU / PCMA | Yes | No | Receive-extension fixture, not native SvxLink EchoLink support |

The production Speex sender remains 15 kbps. Generic SPEEX capability does not
separately negotiate a bitrate. All formats are narrowband, 8 kHz mono. Higher
Speex bitrate does not restore missing high-frequency information or change the
remote sender's incoming bitrate.

## Repeatable Local Gates

Run from a checkout generated with `xcodegen generate`. The script requires
Xcode with the selected iOS simulator runtime. Tests use synthetic callsigns,
local relays, and explicit localhost destinations. They do not authenticate to
EchoLink or contact real stations. Hardware and live-test opt-ins are disabled.

```sh
bash Tools/AudioAudit/test_local_audio_runner.sh
bash Tools/AudioAudit/run_local_audio_tests.sh quick
REVERB_AUDIO_ITERATIONS=3 bash Tools/AudioAudit/run_local_audio_tests.sh stress
bash Tools/AudioAudit/run_local_audio_tests.sh full
REVERB_TEST_CONFIGURATION=Release bash Tools/AudioAudit/run_local_audio_tests.sh full
REVERB_TEST_CONFIGURATION=Release REVERB_AUDIO_ITERATIONS=3 bash Tools/AudioAudit/run_local_audio_tests.sh stress
```

Set `REVERB_TEST_DESTINATION` to another installed simulator, for example
`platform=iOS Simulator,id=YOUR_SIMULATOR_UDID`. Set `REVERB_DERIVED_DATA` to reuse
build products. Each run creates a new result directory under `/tmp`, containing
`tests.xcresult` and `xcodebuild.log`; `REVERB_AUDIO_RESULTS` can select an unused
directory. Failure is propagated as a nonzero exit status. Repetitions do not
retry failures away. Use the aggregate xcresult summary, not the last test
process's summary after a runner restart.

The default configuration is Debug. Release validation retains compiler
optimization while enabling test access and the `REVERB_TESTING` observation
hooks; it does not define `DEBUG` or enable screenshot-mode shortcuts. These
flags apply only to the test invocation, not to distribution archives. Verify
the actual signed Release product separately, including sandbox behavior and
device audio. `REVERB_TEST_CONFIGURATION` accepts only Debug or Release.

The quick gate covers packet formats, sequential codecs, recording, tail flush,
voice/PTT state, capture conversion and callback chunk continuity. The stress
gate adds deterministic jitter, duplicate/reorder/loss, burst stalls, receiver
clock mismatch, queue bounds and virtual-time long-duration soaks. Simulated
time is not a claim that the application ran on hardware for that duration.

Protocol integration uses `AudioEngine(hardwareEnabled: false)` so real codecs,
recording callbacks and activity levels are exercised without opening device
I/O. This is not proof of speaker playback, microphone quality, CoreAudio
stability, or a fix for physical-device audio failures. Hardware mode remains
enabled by default in the app.

## Clean-Speech Comparisons

See [the controlled Speex comparison](SPEEX-BITRATE-COMPARISON.md) and
[reproduction commands](../Tools/AudioAudit/README.md). Keep the original PCM
reference, decoded clips, common gain and raw unaligned outputs. Listen for
fricative smearing, metallic/warbling artifacts, clipping and packet-boundary
clicks. Do not infer perceptual preference from RMS, bitrate, or decoder success.

## Physical Device Gate

Before any real-station test, use a signed device build and complete these local
checks with a consenting tester. Start receive-only; do not enable remote PTT.

1. Play a known clean reference over a local synthetic peer. Verify speaker,
   receiver and wired/Bluetooth output, matching receive level and recordings.
2. Exercise mute/unmute, lock/unlock, interruption, headset removal and route
   changes. Audio must recover without a growing backlog or a stuck session.
3. Use local microphone loopback only to test PTT start/release, quiet/loud voice,
   last-syllable retention and clipping. Confirm the destination is a local
   fixture before enabling synthetic TX. Do not use a live directory station.
4. Repeat bursts, duplicates, loss and Wi-Fi interruption against a controlled
   LAN peer. Capture diagnostics, wall-clock latency, route and sample rate,
   recording, codec/payload counts and any crash logs.
5. Require a clean full regression, a successful signed-device run and human
   listening results before reporting real-world audio readiness.

The opt-in `LiveAudioRoundTripTests/testLocalSpeexSpeechRoundTripAndLossRecovery`
and device-recovery audits exercise hardware separately. Inspect their opt-in
requirements before use; they are deliberately not enabled by the local script.
Source-level SvxLink compatibility and simulated packets are not a running
SvxLink daemon or proprietary EchoLink-client interoperability certification.
