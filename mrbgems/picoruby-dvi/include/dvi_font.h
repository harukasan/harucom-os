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
//
// Compressed fonts (compression != 0): the bitmap is a concatenation of
// per-glyph bitstreams. glyph_offsets[i] is the byte offset of glyph i in
// bitmap. glyph_bbox holds 4 bytes per glyph (x, y, w, h): the tight ink box
// within the glyph cell (w=h=0 for blank glyphs). huff_table holds one code
// length per symbol for a shared canonical Huffman table. Each glyph decodes
// to w*h 4bpp pixels via canonical Huffman over zero-run/literal tokens.
// For compressed fonts glyph_width is the fixed advance width (not a storage
// width) and widths is NULL.

#ifndef DVI_FONT_H
#define DVI_FONT_H

#include <stdint.h>

// Number of symbols in the compressed-font Huffman alphabet:
// 0 unused, 1..15 literal 4bpp nibble, 16..31 run of 1..16 zero pixels.
#define DVI_FONT_HUFF_ALPHABET 32

typedef struct {
  uint8_t glyph_width;   // max glyph width (bitmap storage width; fixed advance if compressed)
  uint8_t glyph_height;  // pixels per glyph vertically
  uint16_t first_char;   // first character code in bitmap array
  uint16_t num_chars;    // number of glyphs in bitmap array
  const uint8_t *bitmap; // glyph bitmap data (1bpp, 4bpp, or compressed bitstream)
  const uint8_t *widths; // per-glyph advance widths (NULL = fixed width)
  uint16_t glyph_stride; // bytes between consecutive glyphs
                         // (0 = auto: ((glyph_width+7)/8) * glyph_height)
  uint8_t bpp;           // bits per pixel: 0 or 1 = 1bpp, 4 = 4bpp anti-aliased
  int8_t bitmap_left;    // min bitmap_left offset (0 or negative),
                         // shifts glyph rendering to cover negative bearing
  uint8_t compression;   // 0 = none, 1 = canonical Huffman + zero-run (4bpp)
  const uint32_t *glyph_offsets; // per-glyph byte offset into bitmap (compressed only)
  const uint8_t *glyph_bbox;     // 4 bytes/glyph: x, y, w, h (compressed only)
  const uint8_t *huff_table;     // DVI_FONT_HUFF_ALPHABET code lengths (compressed only)
} dvi_font_t;

#endif
