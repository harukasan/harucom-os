#include <string.h>
#include <stdlib.h>

#define DVI_FONT_REGISTRY_IMPLEMENTATION
#include "dvi_graphics_draw.h"
#include "uni2jis_table.h"

// Global blend state.
// Drawing functions dispatch to REPLACE-only or blend-aware paths based on
// blend_mode. The REPLACE path uses fill_span/plot_pixel (inlined to memset
// or direct store). The blend path uses blend_span/blend_pixel_at which
// perform per-pixel compositing with source channel pre-extraction.
static enum dvi_graphics_blend_mode blend_mode = DVI_BLEND_REPLACE;
static uint8_t blend_alpha = 255;

void dvi_graphics_set_blend_mode(enum dvi_graphics_blend_mode mode)
{
    blend_mode = mode;
}

void dvi_graphics_set_alpha(uint8_t alpha)
{
    blend_alpha = alpha;
}

// Blend src color onto dst using the current blend mode.
// RGB332: R[7:5] G[4:2] B[1:0].
// Used by write_pixel for single-pixel blending (text, draw_image_masked).
static inline uint8_t blend_pixel(uint8_t dst, uint8_t src)
{
    if (blend_mode == DVI_BLEND_REPLACE)
        return src;

    int sr = (src >> 5) & 7, sg = (src >> 2) & 7, sb = src & 3;
    int dr = (dst >> 5) & 7, dg = (dst >> 2) & 7, db = dst & 3;
    int rr, rg, rb;

    switch (blend_mode) {
    case DVI_BLEND_ADD:
        rr = sr + dr; if (rr > 7) rr = 7;
        rg = sg + dg; if (rg > 7) rg = 7;
        rb = sb + db; if (rb > 3) rb = 3;
        break;
    case DVI_BLEND_SUBTRACT:
        rr = dr - sr; if (rr < 0) rr = 0;
        rg = dg - sg; if (rg < 0) rg = 0;
        rb = db - sb; if (rb < 0) rb = 0;
        break;
    case DVI_BLEND_MULTIPLY:
        rr = sr * dr / 7;
        rg = sg * dg / 7;
        rb = sb * db / 3;
        break;
    case DVI_BLEND_SCREEN:
        rr = 7 - (7 - sr) * (7 - dr) / 7;
        rg = 7 - (7 - sg) * (7 - dg) / 7;
        rb = 3 - (3 - sb) * (3 - db) / 3;
        break;
    case DVI_BLEND_ALPHA: {
        int a = blend_alpha;
        rr = (sr * a + dr * (255 - a)) / 255;
        rg = (sg * a + dg * (255 - a)) / 255;
        rb = (sb * a + db * (255 - a)) / 255;
        break;
    }
    default:
        return src;
    }

    return (uint8_t)((rr << 5) | (rg << 2) | rb);
}

// Write a pixel with blending.
static inline void write_pixel(uint8_t *framebuffer, int offset, uint8_t color)
{
    if (blend_mode == DVI_BLEND_REPLACE)
        framebuffer[offset] = color;
    else
        framebuffer[offset] = blend_pixel(framebuffer[offset], color);
}

const dvi_font_t *dvi_graphics_get_font(int font_id)
{
    if (font_id < 0 || font_id >= (int)DVI_GRAPHICS_FONT_COUNT)
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
            write_pixel(framebuffer, py * fb_width + px, color);
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
                int wgw = wide_font->glyph_width;
                int advance = (wide_font->widths) ? wide_font->widths[jis_idx] : wgw;
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

// Clip span coordinates. Returns 0 if span is invisible.
static inline int clip_span(int width, int height, int *x0, int *x1, int y)
{
    if (y < 0 || y >= height)
        return 0;
    if (*x0 < 0) *x0 = 0;
    if (*x1 >= width) *x1 = width - 1;
    return *x0 <= *x1;
}

// Fill a horizontal span with memset (REPLACE only).
// Inlined into drawing functions for the fast path.
static inline void fill_span(uint8_t *framebuffer, int width, int height,
                             int x0, int x1, int y, uint8_t color)
{
    if (!clip_span(width, height, &x0, &x1, y))
        return;
    memset(&framebuffer[y * width + x0], color, x1 - x0 + 1);
}

// Fill a horizontal span with per-pixel blending.
// Each blend mode has a dedicated loop that pre-extracts the constant source
// channels outside the loop, avoiding redundant work per pixel.
static void blend_span(uint8_t *framebuffer, int width, int height,
                       int x0, int x1, int y, uint8_t color)
{
    if (!clip_span(width, height, &x0, &x1, y))
        return;

    uint8_t *row = &framebuffer[y * width];
    int sr = (color >> 5) & 7, sg = (color >> 2) & 7, sb = color & 3;

    switch (blend_mode) {
    case DVI_BLEND_ALPHA: {
        int a = blend_alpha;
        int inv_a = 255 - a;
        int src_r = sr * a, src_g = sg * a, src_b = sb * a;
        for (int ix = x0; ix <= x1; ix++) {
            uint8_t dst = row[ix];
            int dr = (dst >> 5) & 7, dg = (dst >> 2) & 7, db = dst & 3;
            int rr = (src_r + dr * inv_a) / 255;
            int rg = (src_g + dg * inv_a) / 255;
            int rb = (src_b + db * inv_a) / 255;
            row[ix] = (uint8_t)((rr << 5) | (rg << 2) | rb);
        }
        return;
    }
    case DVI_BLEND_ADD:
        for (int ix = x0; ix <= x1; ix++) {
            uint8_t dst = row[ix];
            int rr = sr + ((dst >> 5) & 7); if (rr > 7) rr = 7;
            int rg = sg + ((dst >> 2) & 7); if (rg > 7) rg = 7;
            int rb = sb + (dst & 3);        if (rb > 3) rb = 3;
            row[ix] = (uint8_t)((rr << 5) | (rg << 2) | rb);
        }
        return;
    case DVI_BLEND_SUBTRACT:
        for (int ix = x0; ix <= x1; ix++) {
            uint8_t dst = row[ix];
            int rr = ((dst >> 5) & 7) - sr; if (rr < 0) rr = 0;
            int rg = ((dst >> 2) & 7) - sg; if (rg < 0) rg = 0;
            int rb = (dst & 3) - sb;        if (rb < 0) rb = 0;
            row[ix] = (uint8_t)((rr << 5) | (rg << 2) | rb);
        }
        return;
    case DVI_BLEND_MULTIPLY:
        for (int ix = x0; ix <= x1; ix++) {
            uint8_t dst = row[ix];
            int rr = sr * ((dst >> 5) & 7) / 7;
            int rg = sg * ((dst >> 2) & 7) / 7;
            int rb = sb * (dst & 3) / 3;
            row[ix] = (uint8_t)((rr << 5) | (rg << 2) | rb);
        }
        return;
    case DVI_BLEND_SCREEN: {
        int inv_sr = 7 - sr, inv_sg = 7 - sg, inv_sb = 3 - sb;
        for (int ix = x0; ix <= x1; ix++) {
            uint8_t dst = row[ix];
            int rr = 7 - inv_sr * (7 - ((dst >> 5) & 7)) / 7;
            int rg = 7 - inv_sg * (7 - ((dst >> 2) & 7)) / 7;
            int rb = 3 - inv_sb * (3 - (dst & 3)) / 3;
            row[ix] = (uint8_t)((rr << 5) | (rg << 2) | rb);
        }
        return;
    }
    default:
        return;
    }
}

// Set a single pixel with direct store (REPLACE only).
// Inlined into drawing functions for the fast path.
static inline void plot_pixel(uint8_t *framebuffer, int width, int height,
                              int x, int y, uint8_t color)
{
    if (x >= 0 && x < width && y >= 0 && y < height)
        framebuffer[y * width + x] = color;
}

// Set a single pixel with blending via write_pixel.
static inline void blend_pixel_at(uint8_t *framebuffer, int width, int height,
                                  int x, int y, uint8_t color)
{
    if (x >= 0 && x < width && y >= 0 && y < height)
        write_pixel(framebuffer, y * width + x, color);
}

// Blend-mode dispatch macros.
// Drawing functions set `int blending = (blend_mode != DVI_BLEND_REPLACE)`
// once, then use these macros in loops. The REPLACE branch inlines to
// memset (DRAW_SPAN) or a direct store (DRAW_PIXEL) with no function call.
// The blend branch calls blend_span/blend_pixel_at.
#define DRAW_SPAN(fb, w, h, x0, x1, y, c) \
    do { if (blending) blend_span(fb, w, h, x0, x1, y, c); \
         else fill_span(fb, w, h, x0, x1, y, c); } while (0)
#define DRAW_PIXEL(fb, w, h, x, y, c) \
    do { if (blending) blend_pixel_at(fb, w, h, x, y, c); \
         else plot_pixel(fb, w, h, x, y, c); } while (0)

void dvi_graphics_draw_line(uint8_t *framebuffer, int width, int height,
                            int x0, int y0, int x1, int y1, uint8_t color)
{
    int blending = (blend_mode != DVI_BLEND_REPLACE);
    int dx = abs(x1 - x0);
    int dy = abs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = (dx > dy ? dx : -dy) / 2;

    for (;;) {
        DRAW_PIXEL(framebuffer, width, height, x0, y0, color);

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

void dvi_graphics_fill_rect(uint8_t *framebuffer, int width, int height,
                            int x, int y, int w, int h, uint8_t color)
{
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > width) w = width - x;
    if (y + h > height) h = height - y;
    if (w <= 0 || h <= 0)
        return;
    int blending = (blend_mode != DVI_BLEND_REPLACE);
    for (int iy = 0; iy < h; iy++)
        DRAW_SPAN(framebuffer, width, height, x, x + w - 1, y + iy, color);
}

void dvi_graphics_draw_rect(uint8_t *framebuffer, int width, int height,
                            int x, int y, int w, int h, uint8_t color)
{
    if (w <= 0 || h <= 0)
        return;

    int blending = (blend_mode != DVI_BLEND_REPLACE);
    int x0 = x, y0 = y;
    int x1 = x + w - 1, y1 = y + h - 1;

    // Top edge
    DRAW_SPAN(framebuffer, width, height, x0, x1, y0, color);

    // Bottom edge
    if (h > 1)
        DRAW_SPAN(framebuffer, width, height, x0, x1, y1, color);

    // Left and right edges (inner rows only)
    int top = (y0 + 1) < 0 ? 0 : y0 + 1;
    int bottom = (y1 - 1) >= height ? height - 1 : y1 - 1;
    for (int iy = top; iy <= bottom; iy++) {
        DRAW_PIXEL(framebuffer, width, height, x0, iy, color);
        if (w > 1)
            DRAW_PIXEL(framebuffer, width, height, x1, iy, color);
    }
}

void dvi_graphics_fill_circle(uint8_t *framebuffer, int width, int height,
                              int cx, int cy, int r, uint8_t color)
{
    if (r < 0)
        return;
    int blending = (blend_mode != DVI_BLEND_REPLACE);
    if (r == 0) {
        DRAW_PIXEL(framebuffer, width, height, cx, cy, color);
        return;
    }

    // Row-by-row fill to avoid duplicate spans (which cause blend artifacts)
    int ix = r;
    int r2 = r * r;
    for (int iy = 0; iy <= r; iy++) {
        int threshold = r2 - iy * iy;
        while (ix * ix > threshold)
            ix--;
        DRAW_SPAN(framebuffer, width, height, cx - ix, cx + ix, cy + iy, color);
        if (iy > 0)
            DRAW_SPAN(framebuffer, width, height, cx - ix, cx + ix, cy - iy, color);
    }
}

void dvi_graphics_draw_circle(uint8_t *framebuffer, int width, int height,
                              int cx, int cy, int r, uint8_t color)
{
    if (r < 0)
        return;
    int blending = (blend_mode != DVI_BLEND_REPLACE);
    if (r == 0) {
        DRAW_PIXEL(framebuffer, width, height, cx, cy, color);
        return;
    }

    // Midpoint circle algorithm (outline only)
    int x = 0, y = r;
    int d = 1 - r;

    while (x <= y) {
        DRAW_PIXEL(framebuffer, width, height, cx + x, cy + y, color);
        DRAW_PIXEL(framebuffer, width, height, cx - x, cy + y, color);
        DRAW_PIXEL(framebuffer, width, height, cx + x, cy - y, color);
        DRAW_PIXEL(framebuffer, width, height, cx - x, cy - y, color);
        DRAW_PIXEL(framebuffer, width, height, cx + y, cy + x, color);
        DRAW_PIXEL(framebuffer, width, height, cx - y, cy + x, color);
        DRAW_PIXEL(framebuffer, width, height, cx + y, cy - x, color);
        DRAW_PIXEL(framebuffer, width, height, cx - y, cy - x, color);

        if (d < 0) {
            d += 2 * x + 3;
        } else {
            d += 2 * (x - y) + 5;
            y--;
        }
        x++;
    }
}

void dvi_graphics_fill_triangle(uint8_t *framebuffer, int width, int height,
                                int x0, int y0, int x1, int y1,
                                int x2, int y2, uint8_t color)
{
    // Sort vertices by y: y0 <= y1 <= y2
    if (y0 > y1) { int t; t = x0; x0 = x1; x1 = t; t = y0; y0 = y1; y1 = t; }
    if (y0 > y2) { int t; t = x0; x0 = x2; x2 = t; t = y0; y0 = y2; y2 = t; }
    if (y1 > y2) { int t; t = x1; x1 = x2; x2 = t; t = y1; y1 = y2; y2 = t; }

    if (y0 == y2)
        return;

    // Scanline fill using fixed-point edge interpolation
    int blending = (blend_mode != DVI_BLEND_REPLACE);
    for (int y = y0; y <= y2; y++) {
        // Edge from v0 to v2 (long edge, always active)
        int xa = x0 + (x2 - x0) * (y - y0) / (y2 - y0);
        int xb;

        if (y < y1) {
            if (y1 == y0)
                xb = x0;
            else
                xb = x0 + (x1 - x0) * (y - y0) / (y1 - y0);
        } else {
            if (y2 == y1)
                xb = x1;
            else
                xb = x1 + (x2 - x1) * (y - y1) / (y2 - y1);
        }

        if (xa > xb) { int t = xa; xa = xb; xb = t; }
        DRAW_SPAN(framebuffer, width, height, xa, xb, y, color);
    }
}

void dvi_graphics_fill_ellipse(uint8_t *framebuffer, int width, int height,
                               int cx, int cy, int rx, int ry, uint8_t color)
{
    int blending = (blend_mode != DVI_BLEND_REPLACE);

    if (rx < 0 || ry < 0)
        return;
    if (rx == 0 && ry == 0) {
        DRAW_PIXEL(framebuffer, width, height, cx, cy, color);
        return;
    }
    if (rx == 0) {
        for (int y = -ry; y <= ry; y++)
            DRAW_PIXEL(framebuffer, width, height, cx, cy + y, color);
        return;
    }
    if (ry == 0) {
        DRAW_SPAN(framebuffer, width, height, cx - rx, cx + rx, cy, color);
        return;
    }

    // Row-by-row fill to avoid duplicate spans (which cause blend artifacts)
    long rx2 = (long)rx * rx;
    long ry2 = (long)ry * ry;
    int ix = rx;
    for (int iy = 0; iy <= ry; iy++) {
        long threshold = rx2 * ry2 - (long)iy * iy * rx2;
        while ((long)ix * ix * ry2 > threshold)
            ix--;
        DRAW_SPAN(framebuffer, width, height, cx - ix, cx + ix, cy + iy, color);
        if (iy > 0)
            DRAW_SPAN(framebuffer, width, height, cx - ix, cx + ix, cy - iy, color);
    }
}

void dvi_graphics_draw_ellipse(uint8_t *framebuffer, int width, int height,
                               int cx, int cy, int rx, int ry, uint8_t color)
{
    int blending = (blend_mode != DVI_BLEND_REPLACE);

    if (rx < 0 || ry < 0)
        return;
    if (rx == 0 && ry == 0) {
        DRAW_PIXEL(framebuffer, width, height, cx, cy, color);
        return;
    }
    if (rx == 0) {
        for (int y = -ry; y <= ry; y++)
            DRAW_PIXEL(framebuffer, width, height, cx, cy + y, color);
        return;
    }
    if (ry == 0) {
        for (int x = -rx; x <= rx; x++)
            DRAW_PIXEL(framebuffer, width, height, cx + x, cy, color);
        return;
    }

    // Midpoint ellipse algorithm (outline only)
    long rx2 = (long)rx * rx;
    long ry2 = (long)ry * ry;
    long two_rx2 = 2 * rx2;
    long two_ry2 = 2 * ry2;

    // Region 1
    int x = 0, y = ry;
    long dx = 0, dy = two_rx2 * y;
    long d1 = ry2 - rx2 * ry + rx2 / 4;

    while (dx < dy) {
        DRAW_PIXEL(framebuffer, width, height, cx + x, cy + y, color);
        DRAW_PIXEL(framebuffer, width, height, cx - x, cy + y, color);
        DRAW_PIXEL(framebuffer, width, height, cx + x, cy - y, color);
        DRAW_PIXEL(framebuffer, width, height, cx - x, cy - y, color);
        x++;
        dx += two_ry2;
        if (d1 < 0) {
            d1 += dx + ry2;
        } else {
            y--;
            dy -= two_rx2;
            d1 += dx - dy + ry2;
        }
    }

    // Region 2
    long d2 = ry2 * ((long)(2 * x + 1) * (2 * x + 1)) / 4
            + rx2 * ((long)(y - 1) * (y - 1))
            - rx2 * ry2;

    while (y >= 0) {
        DRAW_PIXEL(framebuffer, width, height, cx + x, cy + y, color);
        DRAW_PIXEL(framebuffer, width, height, cx - x, cy + y, color);
        DRAW_PIXEL(framebuffer, width, height, cx + x, cy - y, color);
        DRAW_PIXEL(framebuffer, width, height, cx - x, cy - y, color);
        y--;
        dy -= two_rx2;
        if (d2 > 0) {
            d2 += rx2 - dy;
        } else {
            x++;
            dx += two_ry2;
            d2 += dx - dy + rx2;
        }
    }
}

// Check if a point (px, py) relative to center is within the arc's angle range.
// Angles are in 1/1024 of a full turn. Handles wrapping (e.g. start=900, stop=100).
static inline int in_arc_range(int px, int py, int start, int stop)
{
    // Convert (px, py) to angle in 0..1023 using atan2 approximation.
    // We use octant-based lookup: map (px, py) to angle in 1024 units.
    // atan2 approximation for integer coordinates.
    int angle;
    if (px == 0 && py == 0)
        return 1;

    // Use the relation: angle = atan2(py, px) mapped to 0..1023
    // 0 = right (+x), 256 = down (+y), 512 = left (-x), 768 = up (-y)
    int ax = abs(px), ay = abs(py);
    // Quadrant angle (0..256) approximation: 256 * ay / (ax + ay)
    int quadrant_angle;
    if (ax + ay == 0)
        return 1;
    quadrant_angle = (256 * ay + (ax + ay) / 2) / (ax + ay);

    if (px >= 0 && py >= 0)
        angle = quadrant_angle;           // Q1: 0..256
    else if (px < 0 && py >= 0)
        angle = 512 - quadrant_angle;     // Q2: 256..512
    else if (px < 0 && py < 0)
        angle = 512 + quadrant_angle;     // Q3: 512..768
    else
        angle = 1024 - quadrant_angle;    // Q4: 768..1024 -> wrap to 0

    angle &= 1023;

    if (start <= stop)
        return angle >= start && angle <= stop;
    else
        return angle >= start || angle <= stop;
}

void dvi_graphics_fill_arc(uint8_t *framebuffer, int width, int height,
                           int cx, int cy, int r,
                           int start_angle, int stop_angle, uint8_t color)
{
    if (r < 0)
        return;

    start_angle &= 1023;
    stop_angle &= 1023;

    int blending = (blend_mode != DVI_BLEND_REPLACE);

    // Row-by-row fill, testing each pixel against the arc angle range
    int r2 = r * r;
    int ix = r;
    for (int iy = 0; iy <= r; iy++) {
        int threshold = r2 - iy * iy;
        while (ix * ix > threshold)
            ix--;

        // For each row, scan the span and only draw pixels in the arc range
        for (int px = -ix; px <= ix; px++) {
            // Check both +iy and -iy rows
            if (in_arc_range(px, iy, start_angle, stop_angle))
                DRAW_PIXEL(framebuffer, width, height, cx + px, cy + iy, color);
            if (iy > 0 && in_arc_range(px, -iy, start_angle, stop_angle))
                DRAW_PIXEL(framebuffer, width, height, cx + px, cy - iy, color);
        }
    }
}

void dvi_graphics_draw_arc(uint8_t *framebuffer, int width, int height,
                           int cx, int cy, int r,
                           int start_angle, int stop_angle, uint8_t color)
{
    if (r < 0)
        return;

    start_angle &= 1023;
    stop_angle &= 1023;

    int blending = (blend_mode != DVI_BLEND_REPLACE);

    // Midpoint circle algorithm, drawing only pixels in the arc range
    int x = 0, y = r;
    int d = 1 - r;

    while (x <= y) {
        // 8 octant points
        if (in_arc_range( x,  y, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx + x, cy + y, color);
        if (in_arc_range(-x,  y, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx - x, cy + y, color);
        if (in_arc_range( x, -y, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx + x, cy - y, color);
        if (in_arc_range(-x, -y, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx - x, cy - y, color);
        if (in_arc_range( y,  x, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx + y, cy + x, color);
        if (in_arc_range(-y,  x, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx - y, cy + x, color);
        if (in_arc_range( y, -x, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx + y, cy - x, color);
        if (in_arc_range(-y, -x, start_angle, stop_angle)) DRAW_PIXEL(framebuffer, width, height, cx - y, cy - x, color);

        if (d < 0) {
            d += 2 * x + 3;
        } else {
            d += 2 * (x - y) + 5;
            y--;
        }
        x++;
    }
}

void dvi_graphics_draw_thick_line(uint8_t *framebuffer, int width, int height,
                                  int x0, int y0, int x1, int y1,
                                  int thickness, uint8_t color)
{
    if (thickness <= 1) {
        dvi_graphics_draw_line(framebuffer, width, height, x0, y0, x1, y1, color);
        return;
    }

    // Draw the line as a filled parallelogram perpendicular to the direction
    int dx = x1 - x0;
    int dy = y1 - y0;

    if (dx == 0 && dy == 0) {
        // Single point: draw a filled circle
        dvi_graphics_fill_circle(framebuffer, width, height, x0, y0, thickness / 2, color);
        return;
    }

    // For axis-aligned lines, use optimized fill
    int blending = (blend_mode != DVI_BLEND_REPLACE);
    int half = thickness / 2;
    if (dy == 0) {
        // Horizontal line
        int left = x0 < x1 ? x0 : x1;
        int right = x0 < x1 ? x1 : x0;
        for (int iy = -half; iy < thickness - half; iy++)
            DRAW_SPAN(framebuffer, width, height, left, right, y0 + iy, color);
        return;
    }
    if (dx == 0) {
        // Vertical line
        int top = y0 < y1 ? y0 : y1;
        int bot = y0 < y1 ? y1 : y0;
        for (int iy = top; iy <= bot; iy++)
            DRAW_SPAN(framebuffer, width, height, x0 - half, x0 + thickness - half - 1, iy, color);
        return;
    }

    // General case: draw multiple parallel lines offset perpendicular
    // Perpendicular direction scaled by thickness
    // Use Bresenham for each offset line
    int abs_dx = abs(dx);
    int abs_dy = abs(dy);

    if (abs_dx >= abs_dy) {
        // More horizontal: offset in y
        for (int i = -half; i < thickness - half; i++)
            dvi_graphics_draw_line(framebuffer, width, height,
                                   x0, y0 + i, x1, y1 + i, color);
    } else {
        // More vertical: offset in x
        for (int i = -half; i < thickness - half; i++)
            dvi_graphics_draw_line(framebuffer, width, height,
                                   x0 + i, y0, x1 + i, y1, color);
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
