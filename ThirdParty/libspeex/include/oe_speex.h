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
#ifdef __cplusplus
}
#endif
#endif
