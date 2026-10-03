/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "oe_speex.h"
#include "speex/speex.h"
#include <assert.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static int encode_fixture(uint8_t *packet, int frames) {
    void *encoder = speex_encoder_init(&speex_nb_mode);
    int quality = 8;
    speex_encoder_ctl(encoder, SPEEX_SET_QUALITY, &quality);
    SpeexBits bits; speex_bits_init(&bits);
    for (int f = 0; f < frames; ++f) {
        int16_t input[160];
        for (int i = 0; i < 160; ++i) input[i] = (int16_t)(10000*sin((f*160+i)*0.1728));
        assert(speex_encode_int(encoder, input, &bits) == 1);
    }
    speex_bits_insert_terminator(&bits);
    int size = speex_bits_write(&bits, (char *)packet, 512);
    speex_bits_destroy(&bits); speex_encoder_destroy(encoder); return size;
}
int main(void) {
    uint8_t packet[512], shortPacket[512], extraPacket[512];
    int size = encode_fixture(packet, 4), shortSize = encode_fixture(shortPacket, 3), extraSize = encode_fixture(extraPacket, 5);
    void *decoder = oe_speex_create(); assert(decoder);
    int16_t output[640], initial[640];
    assert(oe_speex_decode(decoder, packet, size, output) == 640);
    memcpy(initial, output, sizeof(output));
    long energy = 0; for (int i = 0; i < 640; ++i) energy += abs(output[i]); assert(energy > 10000);
    oe_speex_reset(decoder);
    assert(oe_speex_decode(decoder, packet, size, output) == 640);
    assert(memcmp(initial, output, sizeof(output)) == 0);

    int16_t concealed[1282];
    memset(concealed, 0, sizeof(concealed));
    concealed[0] = 1234;
    concealed[1281] = 5678;
    assert(oe_speex_conceal(decoder, 8, concealed + 1, 1280) == 1280);
    assert(concealed[0] == 1234);
    assert(concealed[1281] == 5678);
    long concealedEnergy = 0;
    for (int i = 1; i <= 1280; ++i) concealedEnergy += abs(concealed[i]);
    assert(concealedEnergy > 0);

    int16_t unchanged[160];
    for (int i = 0; i < 160; ++i) unchanged[i] = (int16_t)(i + 1);
    assert(oe_speex_conceal(decoder, 0, unchanged, 160) == 0);
    assert(oe_speex_conceal(decoder, 9, unchanged, 160) == 0);
    assert(oe_speex_conceal(decoder, 1, unchanged, 159) == 0);
    for (int i = 0; i < 160; ++i) assert(unchanged[i] == i + 1);

    void *concealedDecoder = oe_speex_create(); assert(concealedDecoder);
    void *manualDecoder = speex_decoder_init(&speex_nb_mode); assert(manualDecoder);
    int enhancement = 1;
    assert(speex_decoder_ctl(manualDecoder, SPEEX_SET_ENH, &enhancement) == 0);
    assert(oe_speex_decode(concealedDecoder, packet, size, output) == 640);
    SpeexBits manualBits; speex_bits_init(&manualBits);
    speex_bits_read_from(&manualBits, (char *)packet, size);
    for (int frame = 0; frame < 4; ++frame)
        assert(speex_decode_int(manualDecoder, &manualBits, output + frame * 160) == 0);
    speex_bits_destroy(&manualBits);
    int16_t apiLoss[160], manualLoss[160];
    assert(oe_speex_conceal(concealedDecoder, 1, apiLoss, 160) == 160);
    assert(speex_decode_int(manualDecoder, NULL, manualLoss) == 0);
    assert(memcmp(apiLoss, manualLoss, sizeof(apiLoss)) == 0);
    assert(oe_speex_decode(concealedDecoder, packet, size, output) == 640);
    speex_bits_init(&manualBits);
    speex_bits_read_from(&manualBits, (char *)packet, size);
    int16_t manualNext[640];
    for (int frame = 0; frame < 4; ++frame)
        assert(speex_decode_int(manualDecoder, &manualBits, manualNext + frame * 160) == 0);
    speex_bits_destroy(&manualBits);
    assert(memcmp(output, manualNext, sizeof(output)) == 0);
    oe_speex_reset(concealedDecoder);
    assert(oe_speex_decode(concealedDecoder, packet, size, output) == 640);
    assert(memcmp(initial, output, sizeof(output)) == 0);
    speex_decoder_destroy(manualDecoder);
    oe_speex_destroy(concealedDecoder);
    assert(oe_speex_decode(decoder, shortPacket, shortSize, output) == 0);
    assert(oe_speex_decode(decoder, extraPacket, extraSize, output) == 0);
    assert(oe_speex_decode(decoder, packet, 0, output) == 0);
    assert(oe_speex_decode(decoder, packet, 513, output) == 0);
    assert(oe_speex_decode(decoder, packet, size / 2, output) == 0);
    packet[size] = 0;
    assert(oe_speex_decode(decoder, packet, size + 1, output) == 0);
    assert(oe_speex_decode(decoder, packet, size, output) == 640);
    assert(memcmp(initial, output, sizeof(output)) == 0);
    oe_speex_destroy(decoder);

    int16_t input[640];
    for (int i = 0; i < 640; ++i) input[i] = (int16_t)(10000*sin(i*0.1728));
    void *encoder = oe_speex_encoder_create(); assert(encoder);
    memset(packet, 0, sizeof(packet));
    size = oe_speex_encode(encoder, input, 640, packet, sizeof(packet));
    assert(size == 150); /* Four quality-8 300-bit frames, byte-aligned. */
    decoder = oe_speex_create(); assert(decoder);
    assert(oe_speex_decode(decoder, packet, (size_t)size, output) == 640);
    energy = 0; for (int i = 0; i < 640; ++i) energy += abs(output[i]); assert(energy > 10000);

    uint8_t firstPacket[512];
    memcpy(firstPacket, packet, (size_t)size);
    assert(oe_speex_encode(encoder, input, 640, packet, sizeof(packet)) == size);
    assert(memcmp(firstPacket, packet, (size_t)size) != 0);
    oe_speex_encoder_reset(encoder);
    assert(oe_speex_encode(encoder, input, 640, packet, sizeof(packet)) == size);
    assert(memcmp(firstPacket, packet, (size_t)size) == 0);

    uint8_t guarded[152];
    memset(guarded, 0xA5, sizeof(guarded));
    oe_speex_encoder_reset(encoder);
    assert(oe_speex_encode(encoder, input, 640, guarded + 1, 149) == 0);
    for (size_t i = 0; i < sizeof(guarded); ++i) assert(guarded[i] == 0xA5);
    assert(oe_speex_encode(encoder, input, 640, packet, sizeof(packet)) == size);
    assert(memcmp(firstPacket, packet, (size_t)size) == 0);
    assert(oe_speex_encode(encoder, input, 639, packet, sizeof(packet)) == 0);
    assert(oe_speex_encode(encoder, NULL, 640, packet, sizeof(packet)) == 0);
    assert(oe_speex_encode(encoder, input, 640, NULL, sizeof(packet)) == 0);
    assert(oe_speex_encode(encoder, input, 640, packet, 0) == 0);

    oe_speex_destroy(decoder);
    oe_speex_encoder_destroy(encoder);
    puts("Speex native tests passed: RX validation, bounded loss concealment, state continuity, reset and quality-8 TX");
}
