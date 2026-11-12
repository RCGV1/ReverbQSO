/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "oe_speex.h"
#include "speex/speex.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "%s (line %d)\n", message, __LINE__); exit(1); } \
} while (0)

enum { SAMPLE_RATE = 8000, FRAME_SAMPLES = 160, PACKET_SAMPLES = 640 };

static void word16(FILE *file, uint16_t value) {
    REQUIRE(fputc(value & 255, file) != EOF && fputc(value >> 8, file) != EOF, "write failed");
}
static void word32(FILE *file, uint32_t value) {
    word16(file, value & 65535); word16(file, value >> 16);
}
static void path(char *output, size_t capacity, const char *directory, const char *name) {
    int count = snprintf(output, capacity, "%s/%s", directory, name);
    REQUIRE(count >= 0 && (size_t)count < capacity, "output path too long");
}
static FILE *open_output(const char *directory, const char *name) {
    char filename[4096]; path(filename, sizeof(filename), directory, name);
    FILE *file = fopen(filename, "wb"); REQUIRE(file != NULL, "cannot open output");
    return file;
}
static void wave(const char *directory, const char *name, const int16_t *pcm, size_t count) {
    REQUIRE(count <= (UINT32_MAX - 36) / 2, "WAV too large");
    FILE *file = open_output(directory, name);
    REQUIRE(fwrite("RIFF", 1, 4, file) == 4, "write failed"); word32(file, 36 + (uint32_t)count * 2);
    REQUIRE(fwrite("WAVEfmt ", 1, 8, file) == 8, "write failed");
    word32(file, 16); word16(file, 1); word16(file, 1); word32(file, SAMPLE_RATE);
    word32(file, SAMPLE_RATE * 2); word16(file, 2); word16(file, 16);
    REQUIRE(fwrite("data", 1, 4, file) == 4, "write failed"); word32(file, (uint32_t)count * 2);
    for (size_t i = 0; i < count; ++i) word16(file, (uint16_t)pcm[i]);
    REQUIRE(fclose(file) == 0, "close failed");
}
static double rms(const int16_t *pcm, size_t count) {
    double energy = 0;
    for (size_t i = 0; i < count; ++i) energy += (double)pcm[i] * pcm[i];
    return sqrt(energy / (double)count);
}
static int peak(const int16_t *pcm, size_t count) {
    int result = 0;
    for (size_t i = 0; i < count; ++i) if (abs((int)pcm[i]) > result) result = abs((int)pcm[i]);
    return result;
}
static int best_lag(const int16_t *source, const int16_t *decoded, size_t count) {
    double best = -1;
    int lag = 0;
    for (int offset = 0; offset <= 320; ++offset) {
        double sum = 0, energy = 0, reference = 0;
        for (size_t i = 0; i < count; i += 4) {
            sum += (double)source[i] * decoded[i + offset];
            energy += (double)decoded[i + offset] * decoded[i + offset];
            reference += (double)source[i] * source[i];
        }
        double score = sum / sqrt(energy * reference);
        if (score > best) { best = score; lag = offset; }
    }
    return lag;
}

static void compare_rate(const int16_t *input, size_t count, int quality, int expected_rate,
                         const char *directory, FILE *metrics) {
    void *encoder = speex_encoder_init(&speex_nb_mode);
    void *reference_decoder = speex_decoder_init(&speex_nb_mode);
    void *production_decoder = oe_speex_create();
    void *production_encoder = quality == 8 ? oe_speex_encoder_create() : NULL;
    REQUIRE(encoder && reference_decoder && production_decoder, "codec allocation failed");
    REQUIRE(quality != 8 || production_encoder, "production encoder allocation failed");
    int requested = 25000, complexity = 4, disabled = 0, enhancement = 1;
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_SET_BITRATE, &requested) == 0, "set bitrate failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_SET_QUALITY, &quality) == 0, "set quality failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_SET_COMPLEXITY, &complexity) == 0, "set complexity failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_SET_VBR, &disabled) == 0, "disable VBR failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_SET_VAD, &disabled) == 0, "disable VAD failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_SET_DTX, &disabled) == 0, "disable DTX failed");
    REQUIRE(speex_decoder_ctl(reference_decoder, SPEEX_SET_ENH, &enhancement) == 0, "set enhancement failed");
    int effective = 0, frame_size = 0, encoder_delay = 0, decoder_delay = 0;
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_GET_BITRATE, &effective) == 0, "query bitrate failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_GET_FRAME_SIZE, &frame_size) == 0, "query frame failed");
    REQUIRE(speex_encoder_ctl(encoder, SPEEX_GET_LOOKAHEAD, &encoder_delay) == 0, "query encoder delay failed");
    REQUIRE(speex_decoder_ctl(reference_decoder, SPEEX_GET_LOOKAHEAD, &decoder_delay) == 0, "query decoder delay failed");
    REQUIRE(effective == expected_rate && frame_size == FRAME_SAMPLES, "wrong codec rate or frame size");
    int delay = encoder_delay + decoder_delay;
    REQUIRE(delay >= 0 && delay <= 320, "unexpected codec delay");
    /* One zero packet flushes algorithmic lookahead; it is not lost speech. */
    size_t packets = (count + PACKET_SAMPLES - 1) / PACKET_SAMPLES + 1;
    size_t capacity = packets * PACKET_SAMPLES;
    REQUIRE(capacity >= count + 320, "insufficient flush tail");
    int16_t *decoded = calloc(capacity, sizeof(*decoded)); REQUIRE(decoded, "allocation failed");
    char name[128]; snprintf(name, sizeof(name), "speex-%d.datagrams", effective);
    FILE *records = open_output(directory, name);
    SpeexBits encoder_bits, decoder_bits;
    speex_bits_init(&encoder_bits); speex_bits_init(&decoder_bits);
    int expected_bytes = expected_rate / 100;
    size_t payload_bytes = 0;
    for (size_t packet = 0; packet < packets; ++packet) {
        int16_t source_packet[PACKET_SAMPLES];
        for (int i = 0; i < PACKET_SAMPLES; ++i) {
            size_t position = packet * PACKET_SAMPLES + (size_t)i;
            source_packet[i] = position < count ? input[position] : 0;
        }
        speex_bits_reset(&encoder_bits);
        for (int frame = 0; frame < 4; ++frame) {
            int16_t samples[FRAME_SAMPLES];
            memcpy(samples, source_packet + frame * FRAME_SAMPLES, sizeof(samples));
            REQUIRE(speex_encode_int(encoder, samples, &encoder_bits) == 1, "encode failed");
        }
        speex_bits_insert_terminator(&encoder_bits);
        uint8_t payload[512];
        int bytes = speex_bits_write(&encoder_bits, (char *)payload, sizeof(payload));
        REQUIRE(bytes == expected_bytes, "unexpected payload size");
        payload_bytes += (size_t)bytes;
        if (production_encoder) {
            uint8_t production[512];
            int encoded = oe_speex_encode(production_encoder, source_packet, PACKET_SAMPLES,
                                          production, sizeof(production));
            REQUIRE(encoded == bytes && memcmp(production, payload, bytes) == 0,
                    "15 kbps experiment differs from production encoder");
        }
        int16_t *output = decoded + packet * PACKET_SAMPLES;
        REQUIRE(oe_speex_decode(production_decoder, payload, bytes, output) == PACKET_SAMPLES,
                "production receive adapter rejected packet");
        /* SvxLink's receive branch loads each variable-size bitstream and decodes four frames. */
        int16_t reference[PACKET_SAMPLES];
        speex_bits_read_from(&decoder_bits, (char *)payload, bytes);
        for (int frame = 0; frame < 4; ++frame)
            REQUIRE(speex_decode_int(reference_decoder, &decoder_bits,
                    reference + frame * FRAME_SAMPLES) == 0, "four-frame receive loop failed");
        REQUIRE(memcmp(output, reference, sizeof(reference)) == 0, "receive decoder PCM differs");
        uint16_t sequence = (uint16_t)(65520 + packet);
        uint8_t header[12] = {0xC0, 0x96, sequence >> 8, sequence & 255, 0, 0, 0, 0, 0, 0, 0, 0};
        word16(records, (uint16_t)(12 + bytes));
        REQUIRE(fwrite(header, 1, sizeof(header), records) == sizeof(header), "write failed");
        REQUIRE(fwrite(payload, 1, bytes, records) == (size_t)bytes, "write failed");
    }
    REQUIRE(fclose(records) == 0, "close failed");
    int measured_lag = best_lag(input, decoded, count);
    REQUIRE(abs(measured_lag - delay) <= 1, "measured delay differs from codec lookahead");
    size_t clipped = 0;
    for (size_t i = 0; i < capacity; ++i)
        if (decoded[i] == INT16_MIN || decoded[i] == INT16_MAX) clipped++;
    REQUIRE(clipped == 0, "codec clipping occurred; reduce the common source gain");
    snprintf(name, sizeof(name), "speex-%d.wav", effective);
    wave(directory, name, decoded + delay, count);
    snprintf(name, sizeof(name), "speex-%d-raw-decoded.wav", effective);
    wave(directory, name, decoded, capacity);
    double output_rms = rms(decoded + delay, count);
    fprintf(metrics, "%d,%d,%d,%zu,%d,%zu,%zu,%d,%d,%d,%.9f,%zu\n",
            effective, quality, complexity, packets, expected_bytes, payload_bytes, count,
            delay, measured_lag, peak(decoded + delay, count), output_rms, clipped);
    printf("rate=%d quality=%d complexity=%d packets=%zu bytes=%d decoded=%zu aligned=%zu delay=%d measured_lag=%d peak=%d rms=%.3f clipped=%zu production_pcm_match=yes%s\n",
           effective, quality, complexity, packets, expected_bytes, capacity, count, delay,
           measured_lag, peak(decoded + delay, count), output_rms, clipped,
           quality == 8 ? " production_tx_match=yes" : "");
    speex_bits_destroy(&encoder_bits); speex_bits_destroy(&decoder_bits);
    speex_encoder_destroy(encoder); speex_decoder_destroy(reference_decoder);
    oe_speex_destroy(production_decoder); oe_speex_encoder_destroy(production_encoder);
    free(decoded);
}

int main(int argc, char **argv) {
    REQUIRE(argc == 3, "usage: speex_bitrate_compare input-8k-mono-s16le.pcm existing-output-directory");
    FILE *file = fopen(argv[1], "rb"); REQUIRE(file, "cannot open input");
    REQUIRE(fseek(file, 0, SEEK_END) == 0, "seek failed");
    long size = ftell(file);
    REQUIRE(size > 0 && size <= 32 * 1024 * 1024 && size % 2 == 0, "invalid PCM byte count");
    rewind(file);
    uint8_t *bytes = malloc((size_t)size); REQUIRE(bytes, "allocation failed");
    REQUIRE(fread(bytes, 1, (size_t)size, file) == (size_t)size, "read failed");
    REQUIRE(fclose(file) == 0, "close failed");
    REQUIRE(!(size >= 12 && memcmp(bytes + 8, "WAVE", 4) == 0 &&
              (memcmp(bytes, "RIFF", 4) == 0 || memcmp(bytes, "RIFX", 4) == 0 || memcmp(bytes, "RF64", 4) == 0)),
            "input must be headerless little-endian PCM, not a WAV file");
    size_t count = (size_t)size / 2;
    int16_t *pcm = malloc(count * sizeof(*pcm)); REQUIRE(pcm, "allocation failed");
    for (size_t i = 0; i < count; ++i) pcm[i] = (int16_t)((uint16_t)bytes[2 * i] | (uint16_t)bytes[2 * i + 1] << 8);
    free(bytes);
    int source_peak = peak(pcm, count); REQUIRE(source_peak > 0, "source is silent");
    double gain = 16384.0 / source_peak;
    for (size_t i = 0; i < count; ++i) pcm[i] = (int16_t)lrint(pcm[i] * gain);
    wave(argv[2], "reference.wav", pcm, count);
    printf("source_samples=%zu seconds=%.6f original_peak=%d common_input_gain=%.9f reference_peak=%d reference_rms=%.3f\n",
           count, (double)count / SAMPLE_RATE, source_peak, gain, peak(pcm, count), rms(pcm, count));
    FILE *metrics = open_output(argv[2], "metrics.csv");
    fprintf(metrics, "bitrate_bps,quality,complexity,packets,payload_bytes_per_packet,total_payload_bytes,aligned_samples,codec_delay_samples,measured_lag_samples,aligned_peak,aligned_rms,clipped_samples\n");
    compare_rate(pcm, count, 8, 15000, argv[2], metrics);
    compare_rate(pcm, count, 9, 18200, argv[2], metrics);
    compare_rate(pcm, count, 10, 24600, argv[2], metrics);
    REQUIRE(fclose(metrics) == 0, "close failed");
    free(pcm);
    return 0;
}
