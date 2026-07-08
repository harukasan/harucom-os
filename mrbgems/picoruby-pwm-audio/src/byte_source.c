/*
 * picoruby-pwm-audio/src/byte_source.c
 *
 * See byte_source.h.
 */

#include "byte_source.h"

#include <string.h>

static inline uint32_t
pair_u32(const uint8_t *p)
{
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void
pwm_audio_byte_source_memory(pwm_audio_byte_source_t *source, const uint8_t *data,
                             uint32_t length)
{
  source->single = data;
  source->extent_pairs = NULL;
  source->extent_count = 0;
  source->length = length;
  source->cursor_extent = 0;
  source->cursor_offset = 0;
}

void
pwm_audio_byte_source_extents(pwm_audio_byte_source_t *source, const uint8_t *extent_pairs,
                              uint32_t extent_count, uint32_t length)
{
  source->single = NULL;
  source->extent_pairs = extent_pairs;
  source->extent_count = extent_count;
  source->length = length;
  source->cursor_extent = 0;
  source->cursor_offset = 0;
}

bool
pwm_audio_byte_source_read(pwm_audio_byte_source_t *source, uint32_t offset, void *dst,
                           uint32_t count)
{
  if (offset + count > source->length || offset + count < offset) return false;
  if (source->single) {
    memcpy(dst, source->single + offset, count);
    return true;
  }

  /* Rewind when seeking backward (e.g. a replay); sequential reads
   * resume from the cached extent. */
  uint32_t index = source->cursor_extent;
  uint32_t start = source->cursor_offset;
  if (offset < start) {
    index = 0;
    start = 0;
  }

  /* Find the extent containing offset. */
  while (index < source->extent_count) {
    uint32_t extent_length = pair_u32(source->extent_pairs + index * 8 + 4);
    if (offset < start + extent_length) break;
    start += extent_length;
    index++;
  }

  uint8_t *out = (uint8_t *)dst;
  while (count > 0) {
    if (index >= source->extent_count) return false;
    const uint8_t *pair = source->extent_pairs + index * 8;
    uint32_t extent_length = pair_u32(pair + 4);
    uint32_t within = offset - start;
    uint32_t n = extent_length - within;
    if (n > count) n = count;
    memcpy(out, (const uint8_t *)(uintptr_t)pair_u32(pair) + within, n);
    out += n;
    offset += n;
    count -= n;
    if (count > 0) {
      start += extent_length;
      index++;
    }
  }
  source->cursor_extent = index;
  source->cursor_offset = start;
  return true;
}
