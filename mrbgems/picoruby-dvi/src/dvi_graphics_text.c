// Text rendering functions for DVI graphics mode.
// Separated from dvi_graphics_draw.c for maintainability.

#include <stdint.h>
#include <stddef.h>

#define DVI_FONT_REGISTRY_IMPLEMENTATION
#include "dvi_graphics_draw.h"
#include "dvi_graphics_internal.h"
#include "uni2jis_table.h"

const dvi_font_t *dvi_graphics_get_font(int font_id)
{
    if (font_id < 0 || font_id >= (int)DVI_GRAPHICS_FONT_COUNT)
        return NULL;
    return graphics_fonts[font_id];
}

int dvi_graphics_font_height(int font_id)
{
    const dvi_font_t *font = dvi_graphics_get_font(font_id);
    if (!font)
        return 0;
    return font->glyph_height;
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

// Compute the advance width of a character without rendering.
static int char_advance(int32_t cp, const dvi_font_t *font,
                        const dvi_font_t *wide_font)
{
    int idx = cp - font->first_char;
    if (idx >= 0 && idx < font->num_chars)
        return (font->widths) ? font->widths[idx] : font->glyph_width;

    if (wide_font) {
        int jis_idx = unicode_to_jis_index(cp);
        if (jis_idx >= 0 && jis_idx < wide_font->num_chars)
            return (wide_font->widths) ? wide_font->widths[jis_idx] : wide_font->glyph_width;
    }

    return font->glyph_width;
}

// Blend foreground color onto background using 4-bit alpha (0 = transparent, 15 = opaque).
// Operates on RGB332 colors independently of the global blend mode.
static inline uint8_t blend_aa_pixel(uint8_t bg, uint8_t fg, uint8_t alpha4)
{
    int a = alpha4 * 17;  // map 0-15 to 0-255
    int inv_a = 255 - a;
    int sr = (fg >> 5) & 7, sg = (fg >> 2) & 7, sb = fg & 3;
    int dr = (bg >> 5) & 7, dg = (bg >> 2) & 7, db = bg & 3;
    int rr = (sr * a + dr * inv_a) / 255;
    int rg = (sg * a + dg * inv_a) / 255;
    int rb = (sb * a + db * inv_a) / 255;
    return (uint8_t)((rr << 5) | (rg << 2) | rb);
}

// Render one 4bpp anti-aliased glyph at (char_x, y) and return its advance width.
static int draw_glyph_4bpp(uint8_t *framebuffer, int fb_width, int fb_height,
                            int char_x, int y, int idx,
                            uint8_t color, const dvi_font_t *font)
{
    int gw = font->glyph_width;
    int gh = font->glyph_height;
    int bytes_per_row = (gw + 1) / 2;
    const uint8_t *glyph = &font->bitmap[glyph_offset(font, idx)];

    for (int row = 0; row < gh; row++) {
        int py = y + row;
        if (py < 0)
            continue;
        if (py >= fb_height)
            break;

        const uint8_t *row_data = &glyph[row * bytes_per_row];
        for (int col = 0; col < gw; col++) {
            uint8_t byte_val = row_data[col / 2];
            uint8_t v = (col & 1) ? (byte_val & 0x0F) : (byte_val >> 4);
            if (v == 0)
                continue;
            int px = char_x + font->bitmap_left + col;
            if (px < 0)
                continue;
            if (px >= fb_width)
                break;
            int offset = py * fb_width + px;
            if (v == 15)
                framebuffer[offset] = color;
            else
                framebuffer[offset] = blend_aa_pixel(framebuffer[offset], color, v);
        }
    }

    return (font->widths) ? font->widths[idx] : gw;
}

// Render one 1bpp glyph at (char_x, y) and return its advance width.
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
            dvi_graphics_write_pixel(framebuffer, py * fb_width + px, color);
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
            if (char_x + advance > 0) {
                if (font->bpp == 4)
                    draw_glyph_4bpp(framebuffer, width, height, char_x, y,
                                    idx, color, font);
                else
                    draw_glyph(framebuffer, width, height, char_x, y,
                               idx, color, font);
            }
            char_x += advance;
            continue;
        }

        // Try wide font via Unicode-to-JIS lookup
        if (wide_font) {
            int jis_idx = unicode_to_jis_index(cp);
            if (jis_idx >= 0 && jis_idx < wide_font->num_chars) {
                int wgw = wide_font->glyph_width;
                int advance = (wide_font->widths) ? wide_font->widths[jis_idx] : wgw;
                if (char_x + advance > 0) {
                    if (wide_font->bpp == 4)
                        draw_glyph_4bpp(framebuffer, width, height, char_x, y,
                                        jis_idx, color, wide_font);
                    else
                        draw_glyph(framebuffer, width, height, char_x, y,
                                   jis_idx, color, wide_font);
                }
                char_x += advance;
                continue;
            }
        }

        // Unknown character: advance by primary font width
        char_x += gw;
    }
}

int dvi_graphics_text_width(const char *text, const dvi_font_t *font,
                            const dvi_font_t *wide_font)
{
    int total = 0;
    const char *p = text;
    while (*p) {
        int32_t cp = utf8_decode(&p);
        if (cp < 0)
            continue;
        total += char_advance(cp, font, wide_font);
    }
    return total;
}
