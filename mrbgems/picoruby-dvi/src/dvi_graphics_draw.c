#include <string.h>
#include <stdlib.h>

#define DVI_FONT_REGISTRY_IMPLEMENTATION
#include "dvi_graphics_draw.h"
#include "uni2jis_table.h"

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

void dvi_graphics_draw_rect(uint8_t *framebuffer, int width, int height,
                            int x, int y, int w, int h, uint8_t color)
{
    if (w <= 0 || h <= 0)
        return;

    int x0 = x, y0 = y;
    int x1 = x + w - 1, y1 = y + h - 1;

    // Top edge
    if (y0 >= 0 && y0 < height) {
        int left = x0 < 0 ? 0 : x0;
        int right = x1 >= width ? width - 1 : x1;
        if (left <= right)
            memset(&framebuffer[y0 * width + left], color, right - left + 1);
    }

    // Bottom edge
    if (h > 1 && y1 >= 0 && y1 < height) {
        int left = x0 < 0 ? 0 : x0;
        int right = x1 >= width ? width - 1 : x1;
        if (left <= right)
            memset(&framebuffer[y1 * width + left], color, right - left + 1);
    }

    // Left edge
    if (x0 >= 0 && x0 < width) {
        int top = (y0 + 1) < 0 ? 0 : y0 + 1;
        int bottom = (y1 - 1) >= height ? height - 1 : y1 - 1;
        for (int iy = top; iy <= bottom; iy++)
            framebuffer[iy * width + x0] = color;
    }

    // Right edge
    if (w > 1 && x1 >= 0 && x1 < width) {
        int top = (y0 + 1) < 0 ? 0 : y0 + 1;
        int bottom = (y1 - 1) >= height ? height - 1 : y1 - 1;
        for (int iy = top; iy <= bottom; iy++)
            framebuffer[iy * width + x1] = color;
    }
}

// Fill a horizontal span from x0 to x1 (inclusive) at row y, clipped.
static inline void fill_span(uint8_t *framebuffer, int width, int height,
                             int x0, int x1, int y, uint8_t color)
{
    if (y < 0 || y >= height)
        return;
    if (x0 < 0) x0 = 0;
    if (x1 >= width) x1 = width - 1;
    if (x0 > x1)
        return;
    memset(&framebuffer[y * width + x0], color, x1 - x0 + 1);
}

// Set a single pixel, clipped.
static inline void plot_pixel(uint8_t *framebuffer, int width, int height,
                              int x, int y, uint8_t color)
{
    if (x >= 0 && x < width && y >= 0 && y < height)
        framebuffer[y * width + x] = color;
}

void dvi_graphics_fill_circle(uint8_t *framebuffer, int width, int height,
                              int cx, int cy, int r, uint8_t color)
{
    if (r < 0)
        return;
    if (r == 0) {
        plot_pixel(framebuffer, width, height, cx, cy, color);
        return;
    }

    // Midpoint circle algorithm with horizontal span fill
    int x = 0, y = r;
    int d = 1 - r;

    while (x <= y) {
        fill_span(framebuffer, width, height, cx - x, cx + x, cy + y, color);
        fill_span(framebuffer, width, height, cx - x, cx + x, cy - y, color);
        fill_span(framebuffer, width, height, cx - y, cx + y, cy + x, color);
        fill_span(framebuffer, width, height, cx - y, cx + y, cy - x, color);

        if (d < 0) {
            d += 2 * x + 3;
        } else {
            d += 2 * (x - y) + 5;
            y--;
        }
        x++;
    }
}

void dvi_graphics_draw_circle(uint8_t *framebuffer, int width, int height,
                              int cx, int cy, int r, uint8_t color)
{
    if (r < 0)
        return;
    if (r == 0) {
        plot_pixel(framebuffer, width, height, cx, cy, color);
        return;
    }

    // Midpoint circle algorithm (outline only)
    int x = 0, y = r;
    int d = 1 - r;

    while (x <= y) {
        plot_pixel(framebuffer, width, height, cx + x, cy + y, color);
        plot_pixel(framebuffer, width, height, cx - x, cy + y, color);
        plot_pixel(framebuffer, width, height, cx + x, cy - y, color);
        plot_pixel(framebuffer, width, height, cx - x, cy - y, color);
        plot_pixel(framebuffer, width, height, cx + y, cy + x, color);
        plot_pixel(framebuffer, width, height, cx - y, cy + x, color);
        plot_pixel(framebuffer, width, height, cx + y, cy - x, color);
        plot_pixel(framebuffer, width, height, cx - y, cy - x, color);

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
        fill_span(framebuffer, width, height, xa, xb, y, color);
    }
}

void dvi_graphics_fill_ellipse(uint8_t *framebuffer, int width, int height,
                               int cx, int cy, int rx, int ry, uint8_t color)
{
    if (rx < 0 || ry < 0)
        return;
    if (rx == 0 && ry == 0) {
        plot_pixel(framebuffer, width, height, cx, cy, color);
        return;
    }
    if (rx == 0) {
        // Vertical line
        for (int y = -ry; y <= ry; y++)
            plot_pixel(framebuffer, width, height, cx, cy + y, color);
        return;
    }
    if (ry == 0) {
        fill_span(framebuffer, width, height, cx - rx, cx + rx, cy, color);
        return;
    }

    // Midpoint ellipse algorithm with horizontal span fill
    long rx2 = (long)rx * rx;
    long ry2 = (long)ry * ry;
    long two_rx2 = 2 * rx2;
    long two_ry2 = 2 * ry2;

    // Region 1: dy/dx > -1
    int x = 0, y = ry;
    long dx = 0, dy = two_rx2 * y;
    long d1 = ry2 - rx2 * ry + rx2 / 4;

    while (dx < dy) {
        fill_span(framebuffer, width, height, cx - x, cx + x, cy + y, color);
        fill_span(framebuffer, width, height, cx - x, cx + x, cy - y, color);
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

    // Region 2: dy/dx <= -1
    long d2 = ry2 * ((long)(2 * x + 1) * (2 * x + 1)) / 4
            + rx2 * ((long)(y - 1) * (y - 1))
            - rx2 * ry2;

    while (y >= 0) {
        fill_span(framebuffer, width, height, cx - x, cx + x, cy + y, color);
        fill_span(framebuffer, width, height, cx - x, cx + x, cy - y, color);
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

void dvi_graphics_draw_ellipse(uint8_t *framebuffer, int width, int height,
                               int cx, int cy, int rx, int ry, uint8_t color)
{
    if (rx < 0 || ry < 0)
        return;
    if (rx == 0 && ry == 0) {
        plot_pixel(framebuffer, width, height, cx, cy, color);
        return;
    }
    if (rx == 0) {
        for (int y = -ry; y <= ry; y++)
            plot_pixel(framebuffer, width, height, cx, cy + y, color);
        return;
    }
    if (ry == 0) {
        for (int x = -rx; x <= rx; x++)
            plot_pixel(framebuffer, width, height, cx + x, cy, color);
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
        plot_pixel(framebuffer, width, height, cx + x, cy + y, color);
        plot_pixel(framebuffer, width, height, cx - x, cy + y, color);
        plot_pixel(framebuffer, width, height, cx + x, cy - y, color);
        plot_pixel(framebuffer, width, height, cx - x, cy - y, color);
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
        plot_pixel(framebuffer, width, height, cx + x, cy + y, color);
        plot_pixel(framebuffer, width, height, cx - x, cy + y, color);
        plot_pixel(framebuffer, width, height, cx + x, cy - y, color);
        plot_pixel(framebuffer, width, height, cx - x, cy - y, color);
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
    int half = thickness / 2;
    if (dy == 0) {
        // Horizontal line
        int left = x0 < x1 ? x0 : x1;
        int right = x0 < x1 ? x1 : x0;
        for (int iy = -half; iy < thickness - half; iy++)
            fill_span(framebuffer, width, height, left, right, y0 + iy, color);
        return;
    }
    if (dx == 0) {
        // Vertical line
        int top = y0 < y1 ? y0 : y1;
        int bot = y0 < y1 ? y1 : y0;
        for (int iy = top; iy <= bot; iy++)
            fill_span(framebuffer, width, height, x0 - half, x0 + thickness - half - 1, iy, color);
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
