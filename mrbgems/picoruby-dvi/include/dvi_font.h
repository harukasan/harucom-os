// Font data structure for DVI rendering.
//
// 1bpp bitmap layout: each glyph occupies (bytes_per_row * glyph_height) bytes,
// where bytes_per_row = (glyph_width + 7) / 8. MSB = leftmost pixel.
//
// 4bpp bitmap layout: each pixel is 4 bits (0-15 alpha levels), packed 2 per
// byte with the left pixel in the high nibble. bytes_per_row = (glyph_width + 1) / 2.
// glyph_stride must be set explicitly for 4bpp fonts.
//
// Character lookup: glyph index = character_code - first_char.
// For JIS X 0208 fonts: first_char=0, index = linear JIS index.
//
// Proportional fonts: if widths is non-NULL, widths[i] gives the advance
// width for glyph i. If NULL, all glyphs advance by glyph_width.

#ifndef DVI_FONT_H
#define DVI_FONT_H

#include <stdint.h>

typedef struct {
    uint8_t glyph_width;    // max glyph width (bitmap storage width)
    uint8_t glyph_height;   // pixels per glyph vertically
    uint16_t first_char;    // first character code in bitmap array
    uint16_t num_chars;     // number of glyphs in bitmap array
    const uint8_t *bitmap;  // glyph bitmap data (1bpp or 4bpp)
    const uint8_t *widths;  // per-glyph advance widths (NULL = fixed width)
    uint16_t glyph_stride;  // bytes between consecutive glyphs
                            // (0 = auto: ((glyph_width+7)/8) * glyph_height)
    uint8_t bpp;            // bits per pixel: 0 or 1 = 1bpp, 4 = 4bpp anti-aliased
} dvi_font_t;

#endif
