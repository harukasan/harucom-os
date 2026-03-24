// Font data structure for DVI text mode rendering.

#ifndef DVI_FONT_H
#define DVI_FONT_H

#include <stdint.h>

typedef struct {
    uint8_t glyph_width;   // pixels per glyph horizontally (e.g., 6 for 12px half-width)
    uint8_t glyph_height;  // pixels per glyph vertically (e.g., 13 for 12px font)
    uint16_t first_char;   // first character code in bitmap array
    uint16_t num_chars;    // number of glyphs in bitmap array
    const uint8_t *bitmap; // 1bpp bitmap, one byte per row, MSB = leftmost pixel
} dvi_font_t;

#endif
