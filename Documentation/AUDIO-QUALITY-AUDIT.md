# Audio quality under network impairment

The offline SvxLink impairment audit exercises production GSM/Speex codecs,
EchoLink voice parsing, packet reordering, loss concealment, clock compensation,
and decoded playout buffering. Its renderer uses virtual time so traces are
repeatable without depending on a sound device or a live station.

The matrix covers clean traffic, seeded +/-20 ms jitter, adjacent packet reorder,
duplicates, isolated loss, two-packet loss, a delayed four-packet burst, and a long
stall. Each runs with both codecs and zero or advancing timestamps, for 32 cases.
Sequences cross rollover. A separate localhost UDP test exercises registration,
SDES, real voice datagram admission, duplicate rejection, reorder, and remote BYE
through the production connection service with hardware playback muted.

Additional speech-bearing cases reuse the app's bundled synthesized welcome,
original GSM and a Speex transcode, under clean traffic, jitter, two-packet loss,
and a long stall. Their clean decoded references are codec-specific; a transcode
is not a reference-quality comparison between codecs. All eight cases retain WAV
attachments for listening, in addition to the deterministic voiced/noise fixtures.

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
  -only-testing:ReverbQSOTests/SvxLinkImpairmentAuditTests \
  -only-testing:ReverbQSOTests/SvxLinkLocalPeerTests \
  -only-testing:ReverbQSOTests/EchoLinkAudioReorderBufferTests \
  -only-testing:ReverbQSOTests/ReceiveAudioSoakTests \
  -only-testing:ReverbQSOTests/ReceiveNativeConcealmentSmootherTests clean test
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

When a concealment tail is shortened, its leading boundary is blended from the
preceding speech. If no synthetic samples fit, returning speech blends from that
same preceding speech, not from an unrendered concealment endpoint. This avoids a
click without adding samples or extending the recovery budget.

Native Speex concealment uses a playback-only join repair when its prefix is
discarded. The first 32 retained samples blend from the preceding processed
speech. With fewer than 32 samples retained, the first 80 received samples also
join from the resulting boundary. No samples are added, and clean packets and
untrimmed native concealment remain unchanged. Stream, codec, reset, invalid-time,
and idle boundaries cannot reuse prior speech. The native decoder still advances
through the full missing interval before decoding the returning packet.

Actual Speex encode/decode tests sweep five voiced frequencies, four phases, and
seven output budgets. The largest leading sample step for a 640-sample retained
tail falls from 18,036 to 564 PCM units; for a zero-sample tail it falls from 16,273
to 203. These are pre-gain waveform-continuity measurements, not perceptual scores.
Tests retain before/after WAVs and independently compare native decoder output and
subsequent decoding state with an unclipped reference. The same join policy is
used by iOS playback and forwarded Watch playback.

A deterministic two-packet-loss regression with 320 native samples and 160 decoded
pending samples previously added 1,920 recovery samples, for 2,400 queued samples
(300 ms). It now adds 800, for 1,280 total (160 ms). That removes 140 ms of synthetic
backlog in this case, not 140 ms of network delay. Clean traffic adds no concealment
and follows the existing startup and playback policy.

The virtual-renderer backlog regression measures a separate case: with 240 ms of
real speech already queued, a two-packet loss previously postponed the returning
speech until 410 ms; bounded concealment brings it forward to 250 ms. This removes
160 ms of synthetic delay without discarding the received packet.

In the matrix, clean traffic and +/-20 ms jitter have zero uncovered render time
and zero playback discards for both codecs. The delayed four-packet burst has zero
playback discards. The long-stall case has three stale-audio discards and a maximum
native queue of 321 ms. Accepted packet counts describe decoder admission, not
proof that every sample reached playback. The decoded clean-tail comparison checks
decoder recovery; queue and gap metrics separately describe virtual rendering.

## Reordering with native output headroom

In-order packets are delivered immediately. A sequence gap normally waits 40 ms.
When the native player is actively rendering, a gap may wait for the verified
queued audio duration minus a 20 ms safety margin, capped at 120 ms total. The
oldest pending arrival fixes the deadline; later arrivals cannot extend it.
Decoded pending audio and output preroll do not qualify as verified headroom.
Muted, background, and Watch-forwarded sessions retain the default 40 ms wait.

A GSM/Speex comparison, with both zero and advancing timestamps, delays one packet
until 60 ms after the following packet arrives. With preceding speech already
queued, the old fixed deadline admitted 79 of 80 packets. Headroom-aware waiting
admits all 80 in order, adds no synthetic replacement samples, and has no uncovered
render time or playback discards. This does not add a new startup buffer; it uses
lead already present in the native renderer. It cannot recover packets after
audible headroom has run out, and it does not prevent outages caused by lost Wi-Fi.

## Long-running clock and waveform checks

`ReceiveAudioSoakTests` runs two ten-minute virtual QSOs at 80 ms packet cadence
and two two-minute QSOs at 20 ms cadence, with receiver clocks at +300 and -300 ppm.
Fixed +/-3 ms jitter remains strictly ordered. An actual PCM FIFO consumes samples
at the mismatched clock rate, retaining fractional progress across events. Every
packet must pass through production clock correction and fully reach the renderer;
startup silence is counted separately from later gaps.

These no-loss traces require zero playback discards, overflows, or post-startup
gaps, bounded native capacity, arrival-to-first-sample delay below 150 ms, and
arrival-to-last-sample delay below 250 ms. Settled 30-second mean-delay windows must
vary by less than 10 ms, and final output correction must track the clock mismatch
within 75 ppm. Identity-tagged constant PCM verifies order and sample accounting,
not speech quality. A reset/replay case checks fractional state, pending audio,
timers, and stale completion isolation against a fresh receiver.

Two additional 60-second traces exercise continuous-phase 2873/3371 Hz PCM through
both correction directions. They check every rendered packet join and compare
interior samples with an analytic, endpoint-aligned resampling reference. These
checks cover waveform continuity and upper-speech-band interpolation, not perceived
quality or the effects of an actual codec or audio device.

## Combined network and clock stress

Four 120-second traces combine GSM/Speex with receiver clocks at -1000/+1000 ppm,
seeded +/-15 ms jitter, three intentionally omitted packets, 12 duplicates, a
recoverable reordered pair, and a three-packet Wi-Fi hold. Reordering uses the
default 40 ms wait. The final 30 seconds are clean, allowing decoder and timing
recovery to be checked against a clean sequential reference.

All four runs admit the expected 1,497 unique packets in order, count exactly
three missing packets, and reject only the known duplicates. No unexpected late
packets, invalid decodes, or playback discards occur. Native output peaks at
2,108 samples, decoded waiting peaks at 80 ms, and every scheduled virtual buffer
finishes before teardown. Speech-end delay relative to the source timeline is
80.876 ms at -1000 ppm and 68.262 ms at +1000 ppm, versus 75 ms for the clean
reference. The final second of decoded PCM matches the clean decoder.

Known loss and the Wi-Fi hold still cause 407...458 ms of uncovered virtual
rendering time across each trace. No unexpected packet discard does not mean
uninterrupted speech. These completion/queue checks model a renderer timeline;
the separate long-QSO tests also consume PCM through an explicit sample FIFO.

## Limits

This is a SvxLink-compatible simulated peer and a component audio audit, not a full
SvxLink daemon or an over-the-air radio test. WAV attachments contain seeded
voiced/noise signals or the app's synthesized spoken welcome, not recordings of
human speakers. Virtual output measures local timing, sample preservation, and
waveform properties; it does not certify perceived speech
quality, Bluetooth behavior, microphone acoustics, or real-device render timing.
Missing speech cannot be reconstructed exactly, and a long Wi-Fi outage still
causes an audible interruption. No MOS/PESQ score is inferred from these checks.

Offline regressions exclude live-station tests and opt-in physical audio audits.
Native iPhone/Watch playback, Bluetooth behavior, and route recovery remain
separate field-validation steps; simulator and component passes are not acoustic
or full-daemon interoperability certification.
