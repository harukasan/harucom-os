/*
 * picoruby-pwm-audio/src/byte_source.h
 *
 * Logical byte stream over one contiguous buffer or a list of
 * (address, length) extents, e.g. the flash blocks of a LittleFS file
 * mapped into XIP (see FlashFile.extents). Reads are position based;
 * a cursor remembers the extent of the last read so sequential
 * decoding costs O(1) per read. All reads are plain memory copies,
 * safe inside the render IRQ.
 */

#ifndef PWM_AUDIO_BYTE_SOURCE_DEFINED_H_
#define PWM_AUDIO_BYTE_SOURCE_DEFINED_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  /* contiguous fast path; NULL when extent-based */
  const uint8_t *single;
  /* packed little-endian (u32 address, u32 length) pairs. Addresses
   * are absolute 32-bit memory addresses (XIP), so the extent path is
   * target-only; host builds use the contiguous path. */
  const uint8_t *extent_pairs;
  uint32_t extent_count;
  uint32_t length; /* total logical bytes */
  /* sequential read cursor */
  uint32_t cursor_extent;
  uint32_t cursor_offset; /* logical offset where cursor_extent starts */
} pwm_audio_byte_source_t;

void pwm_audio_byte_source_memory(pwm_audio_byte_source_t *source, const uint8_t *data,
                                  uint32_t length);
void pwm_audio_byte_source_extents(pwm_audio_byte_source_t *source, const uint8_t *extent_pairs,
                                   uint32_t extent_count, uint32_t length);

/* Copy count bytes at the logical offset into dst. Returns false when
 * the range runs past the end of the source. */
bool pwm_audio_byte_source_read(pwm_audio_byte_source_t *source, uint32_t offset, void *dst,
                                uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* PWM_AUDIO_BYTE_SOURCE_DEFINED_H_ */
