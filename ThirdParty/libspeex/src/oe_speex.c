/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "oe_speex.h"
#include "speex/speex.h"
#include <string.h>
#include <stdlib.h>
typedef struct { void *state; } OESpeexDecoder;
void *oe_speex_create(void) {
    OESpeexDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) return NULL;
    decoder->state = speex_decoder_init(&speex_nb_mode);
    if (!decoder->state) { free(decoder); return NULL; }
    return decoder;
}
void oe_speex_destroy(void *handle) {
    OESpeexDecoder *decoder = handle;
    if (decoder) { if (decoder->state) speex_decoder_destroy(decoder->state); free(decoder); }
}
void oe_speex_reset(void *handle) {
    OESpeexDecoder *decoder = handle;
    if (decoder) {
        if (decoder->state) speex_decoder_destroy(decoder->state);
        decoder->state = speex_decoder_init(&speex_nb_mode);
    }
}
int oe_speex_decode(void *handle, const uint8_t *payload, size_t size, int16_t *output) {
    OESpeexDecoder *decoder = handle;
    if (!decoder || !decoder->state || !payload || !output || !size || size > 512) return 0;
    SpeexBits bits;
    int16_t samples[640], extra[160];
    speex_bits_init(&bits);
    speex_bits_read_from(&bits, (char *)payload, (int)size);
    int valid = 1;
    for (int frame = 0; frame < 4; ++frame) {
        if (speex_decode_int(decoder->state, &bits, samples + frame * 160) != 0 ||
            speex_bits_remaining(&bits) < 0) { valid = 0; break; }
    }
    /* An end marker is legal; additional speech or corrupt padding is not. */
    if (valid && (speex_decode_int(decoder->state, &bits, extra) != -1 ||
                  speex_bits_remaining(&bits) > 7)) valid = 0;
    speex_bits_destroy(&bits);
    if (!valid) { oe_speex_reset(decoder); return 0; }
    memcpy(output, samples, sizeof(samples));
    return 640;
}
