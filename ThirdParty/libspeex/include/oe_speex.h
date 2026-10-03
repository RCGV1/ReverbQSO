/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef OE_SPEEX_H
#define OE_SPEEX_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *oe_speex_create(void);
void oe_speex_destroy(void *decoder);
void oe_speex_reset(void *decoder);
/* Four 20 ms narrowband frames (640 samples); returns 640 or 0 on invalid input. */
int oe_speex_decode(void *decoder, const uint8_t *payload, size_t size, int16_t *output);
/* Conceals 1...8 missing 20 ms frames; returns the generated sample count or 0. */
int oe_speex_conceal(void *decoder, size_t frame_count,
                     int16_t *output, size_t output_capacity);

void *oe_speex_encoder_create(void);
void oe_speex_encoder_destroy(void *encoder);
/* Returns 1 when a fresh encoder state is ready, or 0 on failure. */
int oe_speex_encoder_reset(void *encoder);
/* Encodes exactly four 20 ms narrowband frames at quality 8 (15 kbps).
   Returns the packet byte count, or 0 on invalid input or insufficient capacity. */
int oe_speex_encode(void *encoder, const int16_t *input, size_t sample_count,
                    uint8_t *output, size_t output_capacity);
#ifdef __cplusplus
}
#endif
#endif
