/*
 * picoruby-pwm-audio/src/qoa_decoder.h
 *
 * Streaming decoder for the QOA audio format (https://qoaformat.org),
 * decoding mono streams slice by slice (20 samples) so playback needs
 * only the compressed bytes plus this small state. The LMS predictor
 * math and the dequantization table follow the MIT reference
 * implementation by Dominic Szablewski (github.com/phoboslab/qoa).
 * The slice-granular streaming structure is specific to this project:
 * the reference API decodes whole frames (up to 5120 samples), which
 * is too bursty and memory-hungry for rendering inside an IRQ.
 */

#ifndef QOA_DECODER_DEFINED_H_
#define QOA_DECODER_DEFINED_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QOA_SLICE_LEN 20

typedef struct {
  /* compressed stream (owned by the caller) */
  const uint8_t *data;
  uint32_t length;
  /* stream position */
  uint32_t frame_pos; /* byte offset of the next frame header */
  uint32_t slice_pos; /* byte offset of the next slice */
  uint32_t frame_samples_left;
  uint32_t total_samples_left;
  /* LMS predictor; 32-bit like the reference implementation (weights
   * can exceed the int16 range between frame-boundary snapshots) */
  int32_t history[4];
  int32_t weights[4];
  /* decoded slice */
  int16_t slice_samples[QOA_SLICE_LEN];
  uint8_t slice_count;
  uint8_t slice_index;
} qoa_decoder_t;

/* Validate a QOA file header and report the samplerate and total
 * sample count. Only mono streams are accepted. */
bool qoa_decoder_parse_header(const uint8_t *data, uint32_t length, uint32_t *samplerate,
                              uint32_t *frames);

/* Rewind the decoder to the start of the stream. total_samples comes
 * from qoa_decoder_parse_header. */
void qoa_decoder_reset(qoa_decoder_t *decoder, const uint8_t *data, uint32_t length,
                       uint32_t total_samples);

/* Decode the next sample. Returns false at the end of the stream or
 * on malformed data. */
bool qoa_decoder_next(qoa_decoder_t *decoder, int16_t *sample);

#ifdef __cplusplus
}
#endif

#endif /* QOA_DECODER_DEFINED_H_ */
