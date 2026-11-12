# Audio quality under network impairment

The offline SvxLink impairment audit exercises production GSM/Speex codecs,
EchoLink voice parsing, packet reordering, loss concealment, clock compensation,
and decoded playout buffering. Its renderer uses virtual time so traces are
repeatable without depending on a sound device or a live station.

SvxLink's EchoLink voice format uses four 160-sample frames per packet at 8 kHz
(80 ms). Locally encoded packets have a 12-byte legacy RTP header with zero
timestamp and SSRC. The primary fixture follows that format; timestamped traffic
and sequence rollover need separate coverage. The wire contract was checked
against upstream [EchoLinkQso.cpp](https://github.com/sm0svx/svxlink/blob/cba03b33a0b1e83c124da3ab30cff39c7d430ffa/src/echolib/EchoLinkQso.cpp).

## Run

Use an installed iPhone simulator, replacing its name if necessary:

```sh
xcodegen generate
xcodebuild -project ReverbQSO.xcodeproj -scheme ReverbQSO \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:ReverbQSOTests/SvxLinkImpairmentAuditTests test
```

These tests use local fixtures and localhost peers. They do not require an
EchoLink account. Live audit environment variables must remain unset.

## Receive recovery policy

Received speech takes priority over synthesized replacement speech. GSM/G.711
and Speex share a 1,280-sample (160 ms) recovery budget that includes the current
received packet, native renderer lead, and decoded audio still waiting to drain.
Only the newest concealment tail that fits is retained. Decoder/loss state still
advances over the complete confirmed gap; the returning received packet is never
shortened to make space for synthetic audio. The same policy applies to forwarded
Watch receive playback.

A deterministic two-packet-loss regression with 320 native samples and 160 decoded
pending samples previously added 1,920 recovery samples, for 2,400 queued samples
(300 ms). It now adds 800, for 1,280 total (160 ms). That removes 140 ms of synthetic
backlog in this case, not 140 ms of network delay. Clean traffic adds no concealment
and follows the existing startup and playback policy.

## Limits

This is a SvxLink-compatible simulated peer and a component audio audit, not a full
SvxLink daemon or an over-the-air radio test. Virtual output measures local timing,
sample preservation, and waveform properties; it does not certify perceived speech
quality, Bluetooth behavior, microphone acoustics, or real-device render timing.
Missing speech cannot be reconstructed exactly, and a long Wi-Fi outage still
causes an audible interruption. No MOS/PESQ score is inferred from these checks.

The independent full-suite baseline on Xcode 26.0.1/iOS Simulator 26.0 encountered
a CoreAudio RPC abort during demo-session startup. The focused receive audit runs
without a native output device; native iPhone/Watch playback remains a separate
field-validation step.
