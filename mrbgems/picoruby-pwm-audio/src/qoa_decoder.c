/*
 * picoruby-pwm-audio/src/qoa_decoder.c
 *
 * Slice-granular streaming QOA decoder. See qoa_decoder.h for the
 * provenance: the dequantization table and the LMS math are from the
 * QOA specification and its MIT reference implementation.
 */

#include "qoa_decoder.h"

#include <stddef.h>

static const int16_t qoa_dequant_tab[16][8] = {
  {1, -1, 3, -3, 5, -5, 7, -7},
  {5, -5, 18, -18, 32, -32, 49, -49},
  {16, -16, 53, -53, 95, -95, 147, -147},
  {34, -34, 113, -113, 203, -203, 315, -315},
  {63, -63, 210, -210, 378, -378, 588, -588},
  {104, -104, 345, -345, 621, -621, 966, -966},
  {158, -158, 528, -528, 950, -950, 1477, -1477},
  {228, -228, 760, -760, 1368, -1368, 2128, -2128},
  {316, -316, 1053, -1053, 1895, -1895, 2947, -2947},
  {422, -422, 1405, -1405, 2529, -2529, 3934, -3934},
  {548, -548, 1828, -1828, 3290, -3290, 5117, -5117},
  {696, -696, 2320, -2320, 4176, -4176, 6496, -6496},
  {868, -868, 2893, -2893, 5207, -5207, 8099, -8099},
  {1064, -1064, 3548, -3548, 6386, -6386, 9933, -9933},
  {1286, -1286, 4288, -4288, 7718, -7718, 12005, -12005},
  {1536, -1536, 5120, -5120, 9216, -9216, 14336, -14336},
};

static inline uint32_t
read_u16be(const uint8_t *p)
{
  return ((uint32_t)p[0] << 8) | p[1];
}

static inline uint32_t
read_u32be(const uint8_t *p)
{
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static inline uint64_t
read_u64be(const uint8_t *p)
{
  return ((uint64_t)read_u32be(p) << 32) | read_u32be(p + 4);
}

bool
qoa_decoder_parse_header(const uint8_t *data, uint32_t length, uint32_t *samplerate,
                         uint32_t *frames)
{
  /* File header, first frame header, LMS state, and one slice. */
  if (data == NULL || length < 8 + 24 + 8) return false;
  if (data[0] != 'q' || data[1] != 'o' || data[2] != 'a' || data[3] != 'f') return false;
  uint32_t total_samples = read_u32be(data + 4);
  uint8_t channels = data[8];
  uint32_t rate = ((uint32_t)data[9] << 16) | ((uint32_t)data[10] << 8) | data[11];
  if (total_samples == 0 || channels != 1 || rate == 0) return false;
  *samplerate = rate;
  *frames = total_samples;
  return true;
}

void
qoa_decoder_reset(qoa_decoder_t *decoder, const uint8_t *data, uint32_t length,
                  uint32_t total_samples)
{
  decoder->data = data;
  decoder->length = length;
  decoder->frame_pos = 8;
  decoder->slice_pos = 0;
  decoder->frame_samples_left = 0;
  decoder->total_samples_left = total_samples;
  decoder->slice_count = 0;
  decoder->slice_index = 0;
}

/* Enter the next frame: read its header and LMS state. Returns false
 * at the end of the stream or on a malformed frame. */
static bool
read_frame(qoa_decoder_t *decoder)
{
  if (decoder->total_samples_left == 0) return false;
  uint32_t pos = decoder->frame_pos;
  if (pos + 24 > decoder->length) return false;
  const uint8_t *p = decoder->data + pos;
  uint32_t frame_samples = read_u16be(p + 4);
  uint32_t frame_size = read_u16be(p + 6);
  if (p[0] != 1 || frame_samples == 0) return false;
  if (frame_size < 24 || pos + frame_size > decoder->length) return false;
  for (int i = 0; i < 4; i++) {
    decoder->history[i] = (int16_t)read_u16be(p + 8 + i * 2);
    decoder->weights[i] = (int16_t)read_u16be(p + 16 + i * 2);
  }
  if (frame_samples > decoder->total_samples_left) {
    frame_samples = decoder->total_samples_left;
  }
  decoder->frame_samples_left = frame_samples;
  decoder->slice_pos = pos + 24;
  decoder->frame_pos = pos + frame_size;
  return true;
}

/* Decode the next 64-bit slice (up to 20 samples) into the slice
 * buffer. */
static bool
decode_slice(qoa_decoder_t *decoder)
{
  if (decoder->frame_samples_left == 0 && !read_frame(decoder)) return false;
  if (decoder->slice_pos + 8 > decoder->length) return false;
  uint64_t slice = read_u64be(decoder->data + decoder->slice_pos);
  decoder->slice_pos += 8;
  const int16_t *dequant = qoa_dequant_tab[slice >> 60];
  uint32_t n = decoder->frame_samples_left < QOA_SLICE_LEN ? decoder->frame_samples_left
                                                           : QOA_SLICE_LEN;
  for (uint32_t i = 0; i < n; i++) {
    int prediction = (decoder->weights[0] * decoder->history[0] +
                      decoder->weights[1] * decoder->history[1] +
                      decoder->weights[2] * decoder->history[2] +
                      decoder->weights[3] * decoder->history[3]) >>
                     13;
    int dequantized = dequant[(slice >> (57 - i * 3)) & 7];
    int sample = prediction + dequantized;
    if (sample > 32767) sample = 32767;
    if (sample < -32768) sample = -32768;
    int delta = dequantized >> 4;
    for (int w = 0; w < 4; w++) {
      decoder->weights[w] += decoder->history[w] < 0 ? -delta : delta;
    }
    decoder->history[0] = decoder->history[1];
    decoder->history[1] = decoder->history[2];
    decoder->history[2] = decoder->history[3];
    decoder->history[3] = sample;
    decoder->slice_samples[i] = (int16_t)sample;
  }
  decoder->frame_samples_left -= n;
  decoder->total_samples_left -= n;
  decoder->slice_count = (uint8_t)n;
  decoder->slice_index = 0;
  return true;
}

bool
qoa_decoder_next(qoa_decoder_t *decoder, int16_t *sample)
{
  if (decoder->slice_index >= decoder->slice_count && !decode_slice(decoder)) return false;
  *sample = decoder->slice_samples[decoder->slice_index++];
  return true;
}
