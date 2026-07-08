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
qoa_decoder_parse_header(pwm_audio_byte_source_t *source, uint32_t *samplerate,
                         uint32_t *frames, uint32_t *channels)
{
  /* File header, first frame header, mono LMS state, and one slice. */
  if (source == NULL || source->length < 8 + 8 + 16 + 8) return false;
  uint8_t header[12];
  if (!pwm_audio_byte_source_read(source, 0, header, sizeof(header))) return false;
  if (header[0] != 'q' || header[1] != 'o' || header[2] != 'a' || header[3] != 'f') return false;
  uint32_t total_samples = read_u32be(header + 4);
  uint8_t file_channels = header[8];
  uint32_t rate = ((uint32_t)header[9] << 16) | ((uint32_t)header[10] << 8) | header[11];
  if (total_samples == 0 || rate == 0) return false;
  if (file_channels < 1 || file_channels > QOA_MAX_CHANNELS) return false;
  *samplerate = rate;
  *frames = total_samples;
  *channels = file_channels;
  return true;
}

void
qoa_decoder_reset(qoa_decoder_t *decoder, pwm_audio_byte_source_t *source,
                  uint32_t total_samples, uint8_t channels)
{
  decoder->source = source;
  decoder->frame_pos = 8;
  decoder->slice_pos = 0;
  decoder->frame_samples_left = 0;
  decoder->total_samples_left = total_samples;
  decoder->channels = channels;
  decoder->slice_count = 0;
  decoder->slice_index = 0;
}

/* Enter the next frame: read its header and per-channel LMS state.
 * Returns false at the end of the stream or on a malformed frame. */
static bool
read_frame(qoa_decoder_t *decoder)
{
  if (decoder->total_samples_left == 0) return false;
  uint32_t pos = decoder->frame_pos;
  uint32_t header_size = 8 + (uint32_t)decoder->channels * 16;
  uint8_t p[8 + QOA_MAX_CHANNELS * 16];
  if (!pwm_audio_byte_source_read(decoder->source, pos, p, header_size)) return false;
  uint32_t frame_samples = read_u16be(p + 4);
  uint32_t frame_size = read_u16be(p + 6);
  if (p[0] != decoder->channels || frame_samples == 0) return false;
  if (frame_size < header_size || pos + frame_size > decoder->source->length) return false;
  for (int c = 0; c < decoder->channels; c++) {
    const uint8_t *lms = p + 8 + c * 16;
    for (int i = 0; i < 4; i++) {
      decoder->history[c][i] = (int16_t)read_u16be(lms + i * 2);
      decoder->weights[c][i] = (int16_t)read_u16be(lms + 8 + i * 2);
    }
  }
  if (frame_samples > decoder->total_samples_left) {
    frame_samples = decoder->total_samples_left;
  }
  decoder->frame_samples_left = frame_samples;
  decoder->slice_pos = pos + header_size;
  decoder->frame_pos = pos + frame_size;
  return true;
}

/* Decode the next slice group (one 64-bit slice per channel, covering
 * the same span of up to 20 samples) into the slice buffer. */
static bool
decode_slice_group(qoa_decoder_t *decoder)
{
  if (decoder->frame_samples_left == 0 && !read_frame(decoder)) return false;
  uint32_t n = decoder->frame_samples_left < QOA_SLICE_LEN ? decoder->frame_samples_left
                                                           : QOA_SLICE_LEN;
  for (int c = 0; c < decoder->channels; c++) {
    uint8_t slice_bytes[8];
    if (!pwm_audio_byte_source_read(decoder->source, decoder->slice_pos, slice_bytes, 8)) {
      return false;
    }
    uint64_t slice = read_u64be(slice_bytes);
    decoder->slice_pos += 8;
    const int16_t *dequant = qoa_dequant_tab[slice >> 60];
    int32_t *history = decoder->history[c];
    int32_t *weights = decoder->weights[c];
    for (uint32_t i = 0; i < n; i++) {
      int prediction = (weights[0] * history[0] + weights[1] * history[1] +
                        weights[2] * history[2] + weights[3] * history[3]) >>
                       13;
      int dequantized = dequant[(slice >> (57 - i * 3)) & 7];
      int sample = prediction + dequantized;
      if (sample > 32767) sample = 32767;
      if (sample < -32768) sample = -32768;
      int delta = dequantized >> 4;
      for (int w = 0; w < 4; w++) {
        weights[w] += history[w] < 0 ? -delta : delta;
      }
      history[0] = history[1];
      history[1] = history[2];
      history[2] = history[3];
      history[3] = sample;
      decoder->slice_samples[c][i] = (int16_t)sample;
    }
  }
  decoder->frame_samples_left -= n;
  decoder->total_samples_left -= n;
  decoder->slice_count = (uint8_t)n;
  decoder->slice_index = 0;
  return true;
}

bool
qoa_decoder_next(qoa_decoder_t *decoder, int16_t *left, int16_t *right)
{
  if (decoder->slice_index >= decoder->slice_count && !decode_slice_group(decoder)) {
    return false;
  }
  uint8_t i = decoder->slice_index++;
  *left = decoder->slice_samples[0][i];
  *right = decoder->channels == 2 ? decoder->slice_samples[1][i] : *left;
  return true;
}
