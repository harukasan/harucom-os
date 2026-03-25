// Internal shared utilities for dvi_graphics_draw.c and dvi_graphics_text.c.
// Not part of the public API.

#ifndef DVI_GRAPHICS_INTERNAL_H
#define DVI_GRAPHICS_INTERNAL_H

#include <stdint.h>
#include "dvi_graphics_draw.h"

// Write a pixel with blending (defined in dvi_graphics_draw.c).
void dvi_graphics_write_pixel(uint8_t *framebuffer, int offset, uint8_t color);

#endif // DVI_GRAPHICS_INTERNAL_H
