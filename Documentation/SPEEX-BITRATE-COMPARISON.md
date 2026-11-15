# Clean-Speech Speex Profiles

The offline comparison tool in [Tools/AudioAudit](../Tools/AudioAudit/README.md)
uses human speech from the [Open Speech Repository](https://www.voiptroubleshooter.com/open_speech/american.html),
not the GSM-compressed demo voice. Original recordings are mono 8 kHz, 16-bit PCM.
The shared excerpt contains female and male speech, with no simulated loss.

## Controlled Comparison

All profiles use identical input PCM and one common input gain to approximately
-6 dBFS peak. Encoder complexity remains 4; VBR, VAD, and DTX are off. Decoder
enhancement is on. No per-rate gain, EQ, noise processing, or packet loss is added.
The measured 80-sample codec lookahead is removed identically for aligned listening
copies, and raw output is retained. The listening WAVs are decoded PCM: their
container bitrate is not the compressed Speex bitrate.

| Quality | Narrowband Mode | Speex Payload Bitrate | Payload / 80 ms | EchoLink Datagram |
| --- | --- | --- | --- | --- |
| 8 | 5 | 15.0 kbps | 150 bytes | 162 bytes |
| 9 | 6 | 18.2 kbps | 182 bytes | 194 bytes |
| 10 | 7 | 24.6 kbps | 246 bytes | 258 bytes |

All packets contain four 160-sample frames. Effective rates are queried from the
encoder and checked against every payload length. The quality-8 comparison
bitstream must match the production encoder byte-for-byte. No production default
is changed by the tool; unknown/non-Speex peers retain the existing GSM behavior.
The reference is narrowband speech, not a claim of wideband or hi-fi sound.

## Compatibility Evidence

`SpeexBitrateCompatibilityTests` checks all three modes with production legacy
`0xc0`/`0x96` packet parsing, decoding, streaming history, one/two-packet loss,
reset, mode changes, rollover, and rejection/recovery after malformed input.
`SpeexBitrateLocalPeerTests` verifies each profile through the actual connection
service using loopback-only relay/peer fixtures and muted hardware playback.
It checks unique admission, duplicate accounting, zero TX voice packets, decoded
recording PCM, and remote-BYE teardown. These are local integration tests, not
calls to real operators.

The tool independently compares production decoding with the four-frame receive
algorithm in the pinned [SvxLink EchoLinkQso.cpp](https://github.com/sm0svx/svxlink/blob/cba03b33a0b1e83c124da3ab30cff39c7d430ffa/src/echolib/EchoLinkQso.cpp#L785).
The inspected Speex-enabled source accepts the actual payload length, feeds four
frames to a narrowband decoder, and does not enforce a 150-byte or quality-8
receive limit. [Packet storage](https://github.com/sm0svx/svxlink/blob/cba03b33a0b1e83c124da3ab30cff39c7d430ffa/src/echolib/EchoLinkQso.h#L149)
and inspected transport bounds accommodate all three datagrams. The generic
`SPEEX` capability does not separately negotiate bitrate.

This supports source-level compatibility with a Speex-enabled SvxLink receive
path; it is not a running-daemon test. Builds without Speex or with GSM-only
configuration are outside that conclusion. Proprietary EchoLink clients and
external relays are not certified by these tests, so the app default stays at
15 kbps. Higher sender bitrate does not change a remote station's incoming rate.

## Interpretation

Listening, rather than file size or PCM energy alone, should judge differences
in coding artifacts. Bit-exact checks apply to matching build configurations;
portable floating-point Speex can differ by an Int16 unit across optimization
settings without rejecting packets or changing their duration. No MOS/PESQ,
perceptual superiority, hardware playback, or real-station interoperability
claim is inferred from local decode acceptance.
