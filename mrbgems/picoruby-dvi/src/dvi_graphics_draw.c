#include <string.h>
#include <stdlib.h>

#include "dvi_graphics_draw.h"
#include "uni2jis_table.h"
#include "font8x8_basic.h"
#include "font_mplus_f12r.h"
#include "font_mplus_j12_combined.h"
#include "font_fixed_4x6.h"
#include "font_fixed_5x7.h"
#include "font_fixed_6x13.h"
#include "font_spleen_5x8.h"
#include "font_spleen_8x16.h"
#include "font_spleen_12x24.h"
#include "font_denkichip.h"

static const dvi_font_t *const graphics_fonts[] = {
    [DVI_GRAPHICS_FONT_8X8]          = &font8x8_basic,
    [DVI_GRAPHICS_FONT_12PX]         = &font_mplus_f12r,
    [DVI_GRAPHICS_FONT_FIXED_4X6]    = &font_fixed_4x6,
    [DVI_GRAPHICS_FONT_FIXED_5X7]    = &font_fixed_5x7,
    [DVI_GRAPHICS_FONT_FIXED_6X13]   = &font_fixed_6x13,
    [DVI_GRAPHICS_FONT_SPLEEN_5X8]   = &font_spleen_5x8,
    [DVI_GRAPHICS_FONT_SPLEEN_8X16]  = &font_spleen_8x16,
    [DVI_GRAPHICS_FONT_SPLEEN_12X24] = &font_spleen_12x24,
    [DVI_GRAPHICS_FONT_DENKICHIP]    = &font_denkichip,
    [DVI_GRAPHICS_FONT_MPLUS_J12]    = &font_mplus_j12_wide,
};

#define GRAPHICS_FONT_COUNT \
    (sizeof(graphics_fonts) / sizeof(graphics_fonts[0]))

const dvi_font_t *dvi_graphics_get_font(int font_id)
{
    if (font_id < 0 || font_id >= (int)GRAPHICS_FONT_COUNT)
        return NULL;
    return graphics_fonts[font_id];
}

// Decode one UTF-8 codepoint from *p, advance *p past consumed bytes.
// Returns the codepoint, or -1 on invalid sequence.
static int32_t utf8_decode(const char **p)
{
    const uint8_t *s = (const uint8_t *)*p;
    int32_t cp;
    int len;

    if (s[0] < 0x80) {
        cp = s[0]; len = 1;
    } else if ((s[0] & 0xE0) == 0xC0) {
        cp = s[0] & 0x1F; len = 2;
    } else if ((s[0] & 0xF0) == 0xE0) {
        cp = s[0] & 0x0F; len = 3;
    } else if ((s[0] & 0xF8) == 0xF0) {
        cp = s[0] & 0x07; len = 4;
    } else {
        *p += 1;
        return -1;
    }
    for (int i = 1; i < len; i++) {
        if ((s[i] & 0xC0) != 0x80) {
            *p += 1;
            return -1;
        }
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    *p += len;
    return cp;
}

// Unicode to JIS X 0208 lookup.
// Returns linear JIS index, or -1 if not found.
static int unicode_to_jis_index(int32_t cp)
{
    uint16_t jis = uni2jis_lookup(cp);
    if (jis == 0)
        return -1;
    int ku = (jis >> 8) - 0x20;
    int ten = (jis & 0xFF) - 0x20;
    return (ku - 1) * 94 + (ten - 1);
}

// Compute the byte offset for glyph at index idx.
static inline int glyph_offset(const dvi_font_t *font, int idx)
{
    if (font->glyph_stride)
        return idx * font->glyph_stride;
    int bytes_per_row = (font->glyph_width + 7) / 8;
    return idx * bytes_per_row * font->glyph_height;
}

// Render one glyph at (char_x, y) and return its advance width.
static int draw_glyph(uint8_t *framebuffer, int fb_width, int fb_height,
                       int char_x, int y, int idx,
                       uint8_t color, const dvi_font_t *font)
{
    int gw = font->glyph_width;
    int gh = font->glyph_height;
    int bytes_per_row = (gw + 7) / 8;
    const uint8_t *glyph = &font->bitmap[glyph_offset(font, idx)];

    for (int row = 0; row < gh; row++) {
        int py = y + row;
        if (py < 0)
            continue;
        if (py >= fb_height)
            break;

        for (int col = 0; col < gw; col++) {
            int byte_idx = col / 8;
            int bit_idx = 7 - (col % 8);
            if (!(glyph[row * bytes_per_row + byte_idx] & (1 << bit_idx)))
                continue;
            int px = char_x + col;
            if (px < 0)
                continue;
            if (px >= fb_width)
                break;
            framebuffer[py * fb_width + px] = color;
        }
    }

    return (font->widths) ? font->widths[idx] : gw;
}

void dvi_graphics_draw_text(uint8_t *framebuffer, int width, int height,
                            int x, int y, const char *text,
                            uint8_t color, const dvi_font_t *font,
                            const dvi_font_t *wide_font)
{
    int gw = font->glyph_width;
    int first = font->first_char;
    int num = font->num_chars;
    int char_x = x;

    const char *p = text;
    while (*p) {
        int32_t cp = utf8_decode(&p);
        if (cp < 0)
            continue;

        if (char_x >= width)
            break;

        // Try primary font
        int idx = cp - first;
        if (idx >= 0 && idx < num) {
            int advance = (font->widths) ? font->widths[idx] : gw;
            if (char_x + advance > 0)
                draw_glyph(framebuffer, width, height, char_x, y,
                           idx, color, font);
            char_x += advance;
            continue;
        }

        // Try wide font via Unicode-to-JIS lookup
        if (wide_font) {
            int jis_idx = unicode_to_jis_index(cp);
            if (jis_idx >= 0 && jis_idx < wide_font->num_chars) {
                int advance = wide_font->glyph_width;
                if (char_x + advance > 0)
                    draw_glyph(framebuffer, width, height, char_x, y,
                               jis_idx, color, wide_font);
                char_x += advance;
                continue;
            }
        }

        // Unknown character: advance by primary font width
        char_x += gw;
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
