/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "oe_speex.h"
#include "speex/speex.h"
#include <string.h>
#include <stdlib.h>
typedef struct { void *state; } OESpeexDecoder;
typedef struct { void *state; } OESpeexEncoder;

static void *oe_speex_new_decoder_state(void) {
    void *state = speex_decoder_init(&speex_nb_mode);
    int enhancement = 1;
    if (!state) return NULL;
    if (speex_decoder_ctl(state, SPEEX_SET_ENH, &enhancement) != 0) {
        speex_decoder_destroy(state);
        return NULL;
    }
    return state;
}

static void *oe_speex_new_encoder_state(void) {
    void *state = speex_encoder_init(&speex_nb_mode);
    int bitrate = 25000;
    int quality = 8;
    int complexity = 4;
    if (!state) return NULL;
    if (speex_encoder_ctl(state, SPEEX_SET_BITRATE, &bitrate) != 0 ||
        speex_encoder_ctl(state, SPEEX_SET_QUALITY, &quality) != 0 ||
        speex_encoder_ctl(state, SPEEX_SET_COMPLEXITY, &complexity) != 0) {
        speex_encoder_destroy(state);
        return NULL;
    }
    return state;
}

void *oe_speex_create(void) {
    OESpeexDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) return NULL;
    decoder->state = oe_speex_new_decoder_state();
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
        decoder->state = oe_speex_new_decoder_state();
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

int oe_speex_conceal(void *handle, size_t frame_count,
                     int16_t *output, size_t output_capacity) {
    OESpeexDecoder *decoder = handle;
    int16_t samples[8 * 160];
    size_t sample_count;

    if (!decoder || !decoder->state || !output || frame_count == 0 || frame_count > 8)
        return 0;
    sample_count = frame_count * 160;
    if (output_capacity < sample_count) return 0;

    for (size_t frame = 0; frame < frame_count; ++frame) {
        if (speex_decode_int(decoder->state, NULL, samples + frame * 160) != 0) {
            oe_speex_reset(decoder);
            return 0;
        }
    }
    memcpy(output, samples, sample_count * sizeof(*samples));
    return (int)sample_count;
}

void *oe_speex_encoder_create(void) {
    OESpeexEncoder *encoder = calloc(1, sizeof(*encoder));
    if (!encoder) return NULL;
    encoder->state = oe_speex_new_encoder_state();
    if (!encoder->state) { free(encoder); return NULL; }
    return encoder;
}

void oe_speex_encoder_destroy(void *handle) {
    OESpeexEncoder *encoder = handle;
    if (encoder) {
        if (encoder->state) speex_encoder_destroy(encoder->state);
        free(encoder);
    }
}

int oe_speex_encoder_reset(void *handle) {
    OESpeexEncoder *encoder = handle;
    if (encoder) {
        if (encoder->state) speex_encoder_destroy(encoder->state);
        encoder->state = oe_speex_new_encoder_state();
        return encoder->state ? 1 : 0;
    }
    return 0;
}

int oe_speex_encode(void *handle, const int16_t *input, size_t sample_count,
                    uint8_t *output, size_t output_capacity) {
    OESpeexEncoder *encoder = handle;
    SpeexBits bits;
    uint8_t packet[512];
    int size;

    if (!encoder || !encoder->state || !input || sample_count != 640 ||
        !output || output_capacity == 0) return 0;

    speex_bits_init(&bits);
    for (int frame = 0; frame < 4; ++frame) {
        if (speex_encode_int(encoder->state, (int16_t *)input + frame * 160, &bits) != 1) {
            speex_bits_destroy(&bits);
            oe_speex_encoder_reset(encoder);
            return 0;
        }
    }
    speex_bits_insert_terminator(&bits);
    size = speex_bits_nbytes(&bits);
    if (size <= 0 || size > (int)sizeof(packet) || (size_t)size > output_capacity ||
        speex_bits_write(&bits, (char *)packet, (int)sizeof(packet)) != size) {
        speex_bits_destroy(&bits);
        oe_speex_encoder_reset(encoder);
        return 0;
    }
    speex_bits_destroy(&bits);
    memcpy(output, packet, (size_t)size);
    return size;
}
