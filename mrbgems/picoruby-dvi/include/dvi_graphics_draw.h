// Primitive drawing functions for DVI graphics mode (320x240 RGB332).
// All functions operate on a raw framebuffer pointer and are independent
// of DVI hardware.

#ifndef DVI_GRAPHICS_DRAW_H
#define DVI_GRAPHICS_DRAW_H

#include <stdint.h>
#include "dvi_font_registry.h"

// Get built-in font by ID. Returns NULL for unknown IDs.
const dvi_font_t *dvi_graphics_get_font(int font_id);

// Draw a UTF-8 string at pixel position (x, y).
// Characters render left-to-right with per-glyph advance widths.
// If wide_font is non-NULL, codepoints not found in font are looked up
// in wide_font via Unicode-to-JIS conversion (for CJK characters).
void dvi_graphics_draw_text(uint8_t *framebuffer, int width, int height,
                            int x, int y, const char *text,
                            uint8_t color, const dvi_font_t *font,
                            const dvi_font_t *wide_font);

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

// Draw an axis-aligned rectangle outline at (x, y) with size (w, h).
// Clips to framebuffer bounds.
void dvi_graphics_draw_rect(uint8_t *framebuffer, int width, int height,
                            int x, int y, int w, int h, uint8_t color);

// Fill a circle centered at (cx, cy) with radius r.
void dvi_graphics_fill_circle(uint8_t *framebuffer, int width, int height,
                              int cx, int cy, int r, uint8_t color);

// Draw a circle outline centered at (cx, cy) with radius r.
void dvi_graphics_draw_circle(uint8_t *framebuffer, int width, int height,
                              int cx, int cy, int r, uint8_t color);

// Fill a triangle with vertices (x0,y0), (x1,y1), (x2,y2).
void dvi_graphics_fill_triangle(uint8_t *framebuffer, int width, int height,
                                int x0, int y0, int x1, int y1,
                                int x2, int y2, uint8_t color);

#endif // DVI_GRAPHICS_DRAW_H
