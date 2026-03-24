#include <string.h>
#include <stdlib.h>

#include "dvi_graphics_draw.h"
#include "font8x8_basic.h"

// M+ 12px regular font (6x13 half-width)
#include "font_mplus_f12r.h"

static const dvi_font_t *const graphics_fonts[] = {
    [DVI_GRAPHICS_FONT_8X8]  = &font8x8_basic,
    [DVI_GRAPHICS_FONT_12PX] = &font_mplus_f12r,
};

#define GRAPHICS_FONT_COUNT \
    (sizeof(graphics_fonts) / sizeof(graphics_fonts[0]))

const dvi_font_t *dvi_graphics_get_font(int font_id)
{
    if (font_id < 0 || font_id >= (int)GRAPHICS_FONT_COUNT)
        return NULL;
    return graphics_fonts[font_id];
}

void dvi_graphics_draw_text(uint8_t *framebuffer, int width, int height,
                            int x, int y, const char *text,
                            uint8_t color, const dvi_font_t *font)
{
    int gw = font->glyph_width;
    int gh = font->glyph_height;
    int first = font->first_char;
    int num = font->num_chars;
    const uint8_t *bitmap = font->bitmap;

    for (int t = 0; text[t] != '\0'; t++) {
        int char_x = x + t * gw;

        // Skip if entirely off-screen
        if (char_x + gw <= 0)
            continue;
        if (char_x >= width)
            break;

        unsigned char c = (unsigned char)text[t];
        int idx = c - first;
        if (idx < 0 || idx >= num)
            continue;

        const uint8_t *glyph = &bitmap[idx * gh];

        for (int row = 0; row < gh; row++) {
            int py = y + row;
            if (py < 0)
                continue;
            if (py >= height)
                break;

            uint8_t bits = glyph[row];
            for (int col = 0; col < gw; col++) {
                if (!(bits & (0x80 >> col)))
                    continue;
                int px = char_x + col;
                if (px < 0)
                    continue;
                if (px >= width)
                    break;
                framebuffer[py * width + px] = color;
            }
        }
    }
}

void dvi_graphics_draw_line(uint8_t *framebuffer, int width, int height,
                            int x0, int y0, int x1, int y1, uint8_t color)
{
    int dx = abs(x1 - x0);
    int dy = abs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = (dx > dy ? dx : -dy) / 2;

    for (;;) {
        if (x0 >= 0 && x0 < width && y0 >= 0 && y0 < height)
            framebuffer[y0 * width + x0] = color;

        if (x0 == x1 && y0 == y1)
            break;

        int e2 = err;
        if (e2 > -dx) {
            err -= dy;
            x0 += sx;
        }
        if (e2 < dy) {
            err += dx;
            y0 += sy;
        }
    }
}

void dvi_graphics_draw_image(uint8_t *framebuffer, int width, int height,
                             const uint8_t *data, int x, int y,
                             int image_width, int image_height)
{
    // Compute visible source region after clipping
    int src_x = 0, src_y = 0;
    int dst_x = x, dst_y = y;
    int draw_w = image_width, draw_h = image_height;

    if (dst_x < 0) { src_x = -dst_x; draw_w += dst_x; dst_x = 0; }
    if (dst_y < 0) { src_y = -dst_y; draw_h += dst_y; dst_y = 0; }
    if (dst_x + draw_w > width)  draw_w = width - dst_x;
    if (dst_y + draw_h > height) draw_h = height - dst_y;
    if (draw_w <= 0 || draw_h <= 0)
        return;

    for (int row = 0; row < draw_h; row++) {
        memcpy(&framebuffer[(dst_y + row) * width + dst_x],
               &data[(src_y + row) * image_width + src_x],
               draw_w);
    }
}

void dvi_graphics_draw_image_masked(uint8_t *framebuffer, int width, int height,
                                    const uint8_t *data, const uint8_t *mask,
                                    int x, int y,
                                    int image_width, int image_height)
{
    // Compute visible source region after clipping
    int src_x = 0, src_y = 0;
    int dst_x = x, dst_y = y;
    int draw_w = image_width, draw_h = image_height;

    if (dst_x < 0) { src_x = -dst_x; draw_w += dst_x; dst_x = 0; }
    if (dst_y < 0) { src_y = -dst_y; draw_h += dst_y; dst_y = 0; }
    if (dst_x + draw_w > width)  draw_w = width - dst_x;
    if (dst_y + draw_h > height) draw_h = height - dst_y;
    if (draw_w <= 0 || draw_h <= 0)
        return;

    for (int row = 0; row < draw_h; row++) {
        for (int col = 0; col < draw_w; col++) {
            int si = (src_y + row) * image_width + (src_x + col);
            int mask_byte = si >> 3;
            int mask_bit  = si & 7;
            if (!(mask[mask_byte] & (1 << mask_bit)))
                continue;
            framebuffer[(dst_y + row) * width + (dst_x + col)] = data[si];
        }
    }
}
