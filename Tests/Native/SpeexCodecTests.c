/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "oe_speex.h"
#include "speex/speex.h"
#include <assert.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static int encode(uint8_t *packet, int frames) {
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
    int size = encode(packet, 4), shortSize = encode(shortPacket, 3), extraSize = encode(extraPacket, 5);
    void *decoder = oe_speex_create(); assert(decoder);
    int16_t output[640], initial[640];
    assert(oe_speex_decode(decoder, packet, size, output) == 640);
    memcpy(initial, output, sizeof(output));
    long energy = 0; for (int i = 0; i < 640; ++i) energy += abs(output[i]); assert(energy > 10000);
    oe_speex_reset(decoder);
    assert(oe_speex_decode(decoder, packet, size, output) == 640);
    assert(memcmp(initial, output, sizeof(output)) == 0);
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
    puts("Speex native tests passed: four speech frames, bounds, truncation, extra frames, reset and recovery");
}
