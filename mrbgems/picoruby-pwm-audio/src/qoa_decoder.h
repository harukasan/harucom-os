/*
 * picoruby-pwm-audio/src/qoa_decoder.h
 *
 * Streaming decoder for the QOA audio format (https://qoaformat.org),
 * decoding mono or stereo streams slice by slice (20 samples per
 * channel) so playback needs only the compressed bytes plus this
 * small state. The LMS predictor math and the dequantization table
 * follow the MIT reference implementation by Dominic Szablewski
 * (github.com/phoboslab/qoa). The slice-granular streaming structure
 * is specific to this project: the reference API decodes whole frames
 * (up to 5120 samples), which is too bursty and memory-hungry for
 * rendering inside an IRQ.
 */

#ifndef QOA_DECODER_DEFINED_H_
#define QOA_DECODER_DEFINED_H_

#include <stdint.h>
#include <stdbool.h>

#include "byte_source.h"

#ifdef __cplusplus
extern "C" {
#endif

#define QOA_SLICE_LEN     20
#define QOA_MAX_CHANNELS  2

typedef struct {
  /* compressed stream (owned by the caller) */
  pwm_audio_byte_source_t *source;
  /* stream position */
  uint32_t frame_pos; /* byte offset of the next frame header */
  uint32_t slice_pos; /* byte offset of the next slice */
  uint32_t frame_samples_left;  /* per channel */
  uint32_t total_samples_left;  /* per channel */
  uint8_t channels;
  /* LMS predictor per channel; 32-bit like the reference
   * implementation (weights can exceed the int16 range between
   * frame-boundary snapshots) */
  int32_t history[QOA_MAX_CHANNELS][4];
  int32_t weights[QOA_MAX_CHANNELS][4];
  /* decoded slice group (one slice per channel, same 20 samples) */
  int16_t slice_samples[QOA_MAX_CHANNELS][QOA_SLICE_LEN];
  uint8_t slice_count;
  uint8_t slice_index;
} qoa_decoder_t;

/* Validate a QOA file header and report the samplerate, per-channel
 * sample count, and channel count. Mono and stereo are accepted. */
bool qoa_decoder_parse_header(pwm_audio_byte_source_t *source, uint32_t *samplerate,
                              uint32_t *frames, uint32_t *channels);

/* Rewind the decoder to the start of the stream. The source must stay
 * valid while decoding. total_samples and channels come from
 * qoa_decoder_parse_header. */
void qoa_decoder_reset(qoa_decoder_t *decoder, pwm_audio_byte_source_t *source,
                       uint32_t total_samples, uint8_t channels);

/* Decode the next sample pair. A mono stream writes the same value to
 * both sides. Returns false at the end of the stream or on malformed
 * data. */
bool qoa_decoder_next(qoa_decoder_t *decoder, int16_t *left, int16_t *right);

#ifdef __cplusplus
}
#endif

#endif /* QOA_DECODER_DEFINED_H_ */
