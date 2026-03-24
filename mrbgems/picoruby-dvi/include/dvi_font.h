// Font data structure for DVI rendering.
//
// Bitmap layout: each glyph occupies (bytes_per_row * glyph_height) bytes,
// where bytes_per_row = (glyph_width + 7) / 8. MSB = leftmost pixel.
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
    uint8_t glyph_width;   // max glyph width (bitmap storage width)
    uint8_t glyph_height;  // pixels per glyph vertically
    uint16_t first_char;   // first character code in bitmap array
    uint16_t num_chars;    // number of glyphs in bitmap array
    const uint8_t *bitmap; // 1bpp bitmap, one byte per row, MSB = leftmost pixel
    const uint8_t *widths; // per-glyph advance widths (NULL = fixed width)
} dvi_font_t;

#endif
