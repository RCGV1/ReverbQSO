# Offline Speex Bitrate Comparison

This file-only tool compares EchoLink narrowband Speex at 15, 18.2, and 24.6 kbps.
It does not open sockets, contact a station, or change the app's 15 kbps default.

## Source And Preparation

Use clean, uncompressed human speech, not a GSM/MP3 transcode. The example uses
female and male 8 kHz, mono, 16-bit PCM Harvard-sentence recordings from the
[Open Speech Repository](https://www.voiptroubleshooter.com/open_speech/american.html).
Its [conditions](https://www.voiptroubleshooter.com/open_speech/index.html) permit
testing and publication with attribution to **Open Speech Repository**. Keep that
attribution with generated listening examples. Record source checksums for a run.

From the repository root, with `clang`, `curl`, and `ffmpeg` installed:

```sh
OUT=/tmp/reverb-speex-rate-comparison
mkdir -p "$OUT/source"
curl --fail --location --proto '=https' \
  https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0010_8k.wav \
  --output "$OUT/source/OSR_us_000_0010_8k.wav"
curl --fail --location --proto '=https' \
  https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0030_8k.wav \
  --output "$OUT/source/OSR_us_000_0030_8k.wav"
ffprobe -v error -show_streams "$OUT/source/OSR_us_000_0010_8k.wav"
ffprobe -v error -show_streams "$OUT/source/OSR_us_000_0030_8k.wav"
shasum -a 256 "$OUT/source/OSR_us_000_0010_8k.wav" "$OUT/source/OSR_us_000_0030_8k.wav"
```

Prepare one 16.8-second excerpt: 0.2 seconds silence, the first 8 seconds of the
female recording, 0.4 seconds silence, the first 8 seconds of the male recording,
and 0.2 seconds silence. Both source files are already uncompressed 8 kHz PCM;
this preparation does not apply a lossy codec or noise processing.

```sh
ffmpeg -hide_banner -loglevel error \
  -i "$OUT/source/OSR_us_000_0010_8k.wav" \
  -i "$OUT/source/OSR_us_000_0030_8k.wav" \
  -filter_complex 'anullsrc=r=8000:cl=mono,atrim=duration=0.2[p];[0:a]atrim=start=0:end=8,asetpts=PTS-STARTPTS[f];anullsrc=r=8000:cl=mono,atrim=duration=0.4[g];[1:a]atrim=start=0:end=8,asetpts=PTS-STARTPTS[m];anullsrc=r=8000:cl=mono,atrim=duration=0.2[t];[p][f][g][m][t]concat=n=5:v=0:a=1,aformat=sample_fmts=s16:sample_rates=8000:channel_layouts=mono[out]' \
  -map '[out]' -f s16le -acodec pcm_s16le "$OUT/source/excerpt-s16le.pcm"
```

## Build And Run

```sh
clang -O2 -std=c11 -DHAVE_CONFIG_H=1 \
  -I ThirdParty/libspeex/include -I ThirdParty/libspeex/src \
  Tools/AudioAudit/speex_bitrate_compare.c ThirdParty/libspeex/src/*.c \
  -lm -o "$OUT/speex_bitrate_compare"
"$OUT/speex_bitrate_compare" "$OUT/source/excerpt-s16le.pcm" "$OUT"
```

The output directory must exist. Known output filenames are replaced on reruns;
use a dedicated directory. The raw input contract is signed little-endian 16-bit,
8 kHz, mono PCM, at most 32 MiB. A WAV header is not accepted as raw PCM.

## Controls And Outputs

All three encoders see exactly the same PCM after one common scaling to a
16,384-sample peak, approximately -6 dBFS. There is no rate-specific output gain,
loudness normalization, equalizer, packet loss, or loss concealment. Encoder
complexity is 4; VBR, VAD, and DTX are off; decoder enhancement is on.

Quality 8/9/10 selects 15,000/18,200/24,600 bps. Every 80 ms packet contains four
20 ms frames and exactly 150/182/246 payload bytes. Effective bitrate and frame
size are queried rather than inferred from a requested setting. The 15 kbps
experimental bitstream must match the production encoder for every packet.

Every payload is decoded both by `oe_speex_decode` and a separate four-frame
`speex_decode_int` loop matching the receive algorithm in
[SvxLink EchoLinkQso.cpp](https://github.com/sm0svx/svxlink/blob/cba03b33a0b1e83c124da3ab30cff39c7d430ffa/src/echolib/EchoLinkQso.cpp).
PCM must match exactly across the full stream. This is algorithm/bitstream-level
evidence, not a launched SvxLink daemon or proprietary EchoLink-client test.

- `reference.wav`: shared uncompressed, commonly scaled source.
- `speex-15000.wav`, `speex-18200.wav`, `speex-24600.wav`: aligned listening clips, same length and sample rate as the reference.
- `speex-*-raw-decoded.wav`: complete, unaligned codec output including the zero-padded flush packet.
- `speex-*.datagrams`: little-endian 16-bit record length followed by one complete EchoLink datagram, with a 12-byte `0xC0`/`0x96` header, wrapping sequence, and zero timestamp/SSRC. These files are not network transmissions.
- `metrics.csv`: measured settings, payload sizes, sample counts, lookahead/alignment, peak, RMS, and clipped-sample counts.

The sum of encoder/decoder lookahead is removed identically from each listening
clip; one extra zero packet provides the flush tail. The observed cross-correlation
lag must agree within one sample. This aligns files for listening; it does not
remove actual runtime packetization or network latency. Raw files are preserved.
Clipping causes the tool to fail. Bitrate, RMS, and waveform checks are not MOS,
PESQ, intelligibility, or proof of perceptual superiority.
