# Speex 1.2.1

Official codec library sources from https://downloads.xiph.org/releases/speex/speex-1.2.1.tar.gz. See COPYING and individual source copyright notices (BSD license). No command-line tools, tests, or optional Vorbis psychoacoustic implementation are included. config.h selects portable floating point without CPU intrinsics. The public include files use standard fixed-width integer types.

EchoLink framing is independently confirmed by [SvxLink](https://github.com/sm0svx/svxlink/blob/fcd13014810af75d1852b3f2cfc8d9806178d0ab/src/echolib/EchoLinkQso.cpp): payload byte 0x96, four 20 ms narrowband frames concatenated into a Speex bitstream with a terminator. Transmit uses mono 8 kHz, quality 8 and complexity 4 (150-byte payloads), matching that interoperable profile. The legacy bare `SPEEX` SDES PRIV capability precedes port and pad items because EchoLib reads only the first PRIV item. Unknown peers receive GSM. SvxLink source is reference material only and is not included or copied. oe_speex.c is an original bounded encoding/decoding adapter.

Release archive SHA-256: `4b44d4f2b38a370a2d98a78329fefc56a0cf93d1c1be70029217baae6628feea`.
