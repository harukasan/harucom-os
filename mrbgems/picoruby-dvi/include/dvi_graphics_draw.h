// Primitive drawing functions for DVI graphics mode (320x240 RGB332).
// All functions operate on a raw framebuffer pointer and are independent
// of DVI hardware.

#ifndef DVI_GRAPHICS_DRAW_H
#define DVI_GRAPHICS_DRAW_H

#include <stdint.h>
#include "dvi_font.h"

// Font ID constants (used by Ruby bindings)
#define DVI_GRAPHICS_FONT_8X8       0
#define DVI_GRAPHICS_FONT_12PX      1
#define DVI_GRAPHICS_FONT_FIXED_4X6  2
#define DVI_GRAPHICS_FONT_FIXED_5X7  3
#define DVI_GRAPHICS_FONT_FIXED_6X13 4
#define DVI_GRAPHICS_FONT_SPLEEN_5X8  5
#define DVI_GRAPHICS_FONT_SPLEEN_8X16 6
#define DVI_GRAPHICS_FONT_SPLEEN_12X24 7
#define DVI_GRAPHICS_FONT_DENKICHIP    8

// Get built-in font by ID. Returns NULL for unknown IDs.
const dvi_font_t *dvi_graphics_get_font(int font_id);

// Draw a null-terminated ASCII string at pixel position (x, y).
// Characters render left-to-right, spaced by font->glyph_width pixels.
// Clips to framebuffer bounds per pixel.
void dvi_graphics_draw_text(uint8_t *framebuffer, int width, int height,
                            int x, int y, const char *text,
                            uint8_t color, const dvi_font_t *font);

// Draw a line from (x0, y0) to (x1, y1) using Bresenham's algorithm.
// Clips each pixel to framebuffer bounds.
void dvi_graphics_draw_line(uint8_t *framebuffer, int width, int height,
                            int x0, int y0, int x1, int y1, uint8_t color);

// Blit an RGB332 image (row-major byte array) at position (x, y).
// Clips to framebuffer bounds.
void dvi_graphics_draw_image(uint8_t *framebuffer, int width, int height,
                             const uint8_t *data, int x, int y,
                             int image_width, int image_height);

// Blit an RGB332 image with a 1bpp transparency mask.
// Mask is packed LSB-first: bit (N % 8) of byte (N / 8) corresponds to
// pixel N in row-major order. Bit=1 means opaque, bit=0 means transparent.
void dvi_graphics_draw_image_masked(uint8_t *framebuffer, int width, int height,
                                    const uint8_t *data, const uint8_t *mask,
                                    int x, int y,
                                    int image_width, int image_height);

#endif // DVI_GRAPHICS_DRAW_H
