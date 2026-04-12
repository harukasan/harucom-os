#include <string.h>
#include <stdlib.h>
#include <math.h>

#include "dvi_graphics_draw.h"

// Global blend state.
// Drawing functions dispatch to REPLACE-only or blend-aware paths based on
// blend_mode. The REPLACE path uses fill_span/plot_pixel (inlined to memset
// or direct store). The blend path uses blend_span/blend_pixel_at which
// perform per-pixel compositing with source channel pre-extraction.
static enum dvi_graphics_blend_mode blend_mode = DVI_BLEND_REPLACE;
static uint8_t blend_alpha = 255;

void
dvi_graphics_set_blend_mode(enum dvi_graphics_blend_mode mode)
{
  blend_mode = mode;
}

void
dvi_graphics_set_alpha(uint8_t alpha)
{
  blend_alpha = alpha;
}

// Blend src color onto dst using the current blend mode.
// RGB332: R[7:5] G[4:2] B[1:0].
// Used by write_pixel for single-pixel blending (text, draw_image_masked).
static inline uint8_t
blend_pixel(uint8_t dst, uint8_t src)
{
  if (blend_mode == DVI_BLEND_REPLACE) return src;

  int sr = (src >> 5) & 7, sg = (src >> 2) & 7, sb = src & 3;
  int dr = (dst >> 5) & 7, dg = (dst >> 2) & 7, db = dst & 3;
  int rr, rg, rb;

  switch (blend_mode) {
  case DVI_BLEND_ADD:
    rr = sr + dr;
    if (rr > 7) rr = 7;
    rg = sg + dg;
    if (rg > 7) rg = 7;
    rb = sb + db;
    if (rb > 3) rb = 3;
    break;
  case DVI_BLEND_SUBTRACT:
    rr = dr - sr;
    if (rr < 0) rr = 0;
    rg = dg - sg;
    if (rg < 0) rg = 0;
    rb = db - sb;
    if (rb < 0) rb = 0;
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
// Also exported via dvi_graphics_internal.h for use by dvi_graphics_text.c.
static inline void
write_pixel(uint8_t *framebuffer, int offset, uint8_t color)
{
  if (blend_mode == DVI_BLEND_REPLACE)
    framebuffer[offset] = color;
  else
    framebuffer[offset] = blend_pixel(framebuffer[offset], color);
}

void
dvi_graphics_write_pixel(uint8_t *framebuffer, int offset, uint8_t color)
{
  write_pixel(framebuffer, offset, color);
}

// Text rendering functions are in dvi_graphics_text.c.

// Clip span coordinates. Returns 0 if span is invisible.
static inline int
clip_span(int width, int height, int *x0, int *x1, int y)
{
  if (y < 0 || y >= height) return 0;
  if (*x0 < 0) *x0 = 0;
  if (*x1 >= width) *x1 = width - 1;
  return *x0 <= *x1;
}

// Fill a horizontal span with memset (REPLACE only).
// Inlined into drawing functions for the fast path.
static inline void
fill_span(uint8_t *framebuffer, int width, int height, int x0, int x1, int y, uint8_t color)
{
  if (!clip_span(width, height, &x0, &x1, y)) return;
  memset(&framebuffer[y * width + x0], color, x1 - x0 + 1);
}

// Fill a horizontal span with per-pixel blending.
// Each blend mode has a dedicated loop that pre-extracts the constant source
// channels outside the loop, avoiding redundant work per pixel.
static void
blend_span(uint8_t *framebuffer, int width, int height, int x0, int x1, int y, uint8_t color)
{
  if (!clip_span(width, height, &x0, &x1, y)) return;

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
      int rr = sr + ((dst >> 5) & 7);
      if (rr > 7) rr = 7;
      int rg = sg + ((dst >> 2) & 7);
      if (rg > 7) rg = 7;
      int rb = sb + (dst & 3);
      if (rb > 3) rb = 3;
      row[ix] = (uint8_t)((rr << 5) | (rg << 2) | rb);
    }
    return;
  case DVI_BLEND_SUBTRACT:
    for (int ix = x0; ix <= x1; ix++) {
      uint8_t dst = row[ix];
      int rr = ((dst >> 5) & 7) - sr;
      if (rr < 0) rr = 0;
      int rg = ((dst >> 2) & 7) - sg;
      if (rg < 0) rg = 0;
      int rb = (dst & 3) - sb;
      if (rb < 0) rb = 0;
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
static inline void
plot_pixel(uint8_t *framebuffer, int width, int height, int x, int y, uint8_t color)
{
  if (x >= 0 && x < width && y >= 0 && y < height) framebuffer[y * width + x] = color;
}

// Set a single pixel with blending via write_pixel.
static inline void
blend_pixel_at(uint8_t *framebuffer, int width, int height, int x, int y, uint8_t color)
{
  if (x >= 0 && x < width && y >= 0 && y < height) write_pixel(framebuffer, y * width + x, color);
}

// Blend-mode dispatch macros.
// Drawing functions set `int blending = (blend_mode != DVI_BLEND_REPLACE)`
// once, then use these macros in loops. The REPLACE branch inlines to
// memset (DRAW_SPAN) or a direct store (DRAW_PIXEL) with no function call.
// The blend branch calls blend_span/blend_pixel_at.
#define DRAW_SPAN(fb, w, h, x0, x1, y, c)                                                          \
  do {                                                                                             \
    if (blending)                                                                                  \
      blend_span(fb, w, h, x0, x1, y, c);                                                          \
    else                                                                                           \
      fill_span(fb, w, h, x0, x1, y, c);                                                           \
  } while (0)
#define DRAW_PIXEL(fb, w, h, x, y, c)                                                              \
  do {                                                                                             \
    if (blending)                                                                                  \
      blend_pixel_at(fb, w, h, x, y, c);                                                           \
    else                                                                                           \
      plot_pixel(fb, w, h, x, y, c);                                                               \
  } while (0)

void
dvi_graphics_draw_line(uint8_t *framebuffer, int width, int height, int x0, int y0, int x1, int y1,
                       uint8_t color)
{
  int blending = (blend_mode != DVI_BLEND_REPLACE);
  int dx = abs(x1 - x0);
  int dy = abs(y1 - y0);
  int sx = x0 < x1 ? 1 : -1;
  int sy = y0 < y1 ? 1 : -1;
  int err = (dx > dy ? dx : -dy) / 2;

  for (;;) {
    DRAW_PIXEL(framebuffer, width, height, x0, y0, color);

    if (x0 == x1 && y0 == y1) break;

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

void
dvi_graphics_fill_rect(uint8_t *framebuffer, int width, int height, int x, int y, int w, int h,
                       uint8_t color)
{
  if (x < 0) {
    w += x;
    x = 0;
  }
  if (y < 0) {
    h += y;
    y = 0;
  }
  if (x + w > width) w = width - x;
  if (y + h > height) h = height - y;
  if (w <= 0 || h <= 0) return;
  int blending = (blend_mode != DVI_BLEND_REPLACE);
  for (int iy = 0; iy < h; iy++)
    DRAW_SPAN(framebuffer, width, height, x, x + w - 1, y + iy, color);
}

void
dvi_graphics_draw_rect(uint8_t *framebuffer, int width, int height, int x, int y, int w, int h,
                       uint8_t color)
{
  if (w <= 0 || h <= 0) return;

  int blending = (blend_mode != DVI_BLEND_REPLACE);
  int x0 = x, y0 = y;
  int x1 = x + w - 1, y1 = y + h - 1;

  // Top edge
  DRAW_SPAN(framebuffer, width, height, x0, x1, y0, color);

  // Bottom edge
  if (h > 1) DRAW_SPAN(framebuffer, width, height, x0, x1, y1, color);

  // Left and right edges (inner rows only)
  int top = (y0 + 1) < 0 ? 0 : y0 + 1;
  int bottom = (y1 - 1) >= height ? height - 1 : y1 - 1;
  for (int iy = top; iy <= bottom; iy++) {
    DRAW_PIXEL(framebuffer, width, height, x0, iy, color);
    if (w > 1) DRAW_PIXEL(framebuffer, width, height, x1, iy, color);
  }
}

void
dvi_graphics_fill_circle(uint8_t *framebuffer, int width, int height, int cx, int cy, int r,
                         uint8_t color)
{
  if (r < 0) return;
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
    if (iy > 0) DRAW_SPAN(framebuffer, width, height, cx - ix, cx + ix, cy - iy, color);
  }
}

void
dvi_graphics_draw_circle(uint8_t *framebuffer, int width, int height, int cx, int cy, int r,
                         uint8_t color)
{
  if (r < 0) return;
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

void
dvi_graphics_fill_triangle(uint8_t *framebuffer, int width, int height, int x0, int y0, int x1,
                           int y1, int x2, int y2, uint8_t color)
{
  // Sort vertices by y: y0 <= y1 <= y2
  if (y0 > y1) {
    int t;
    t = x0;
    x0 = x1;
    x1 = t;
    t = y0;
    y0 = y1;
    y1 = t;
  }
  if (y0 > y2) {
    int t;
    t = x0;
    x0 = x2;
    x2 = t;
    t = y0;
    y0 = y2;
    y2 = t;
  }
  if (y1 > y2) {
    int t;
    t = x1;
    x1 = x2;
    x2 = t;
    t = y1;
    y1 = y2;
    y2 = t;
  }

  if (y0 == y2) return;

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

    if (xa > xb) {
      int t = xa;
      xa = xb;
      xb = t;
    }
    DRAW_SPAN(framebuffer, width, height, xa, xb, y, color);
  }
}

void
dvi_graphics_fill_ellipse(uint8_t *framebuffer, int width, int height, int cx, int cy, int rx,
                          int ry, uint8_t color)
{
  int blending = (blend_mode != DVI_BLEND_REPLACE);

  if (rx < 0 || ry < 0) return;
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
    if (iy > 0) DRAW_SPAN(framebuffer, width, height, cx - ix, cx + ix, cy - iy, color);
  }
}

void
dvi_graphics_draw_ellipse(uint8_t *framebuffer, int width, int height, int cx, int cy, int rx,
                          int ry, uint8_t color)
{
  int blending = (blend_mode != DVI_BLEND_REPLACE);

  if (rx < 0 || ry < 0) return;
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
  long d2 =
      ry2 * ((long)(2 * x + 1) * (2 * x + 1)) / 4 + rx2 * ((long)(y - 1) * (y - 1)) - rx2 * ry2;

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

// Compute segment count for arc based on radius and angle span.
static int
arc_segments(int r, float span)
{
  float abs_span = span < 0 ? -span : span;
  int segs = (int)(abs_span * r / 8.0f);
  if (segs < 4) segs = 4;
  if (segs > 64) segs = 64;
  return segs;
}

void
dvi_graphics_fill_arc(uint8_t *framebuffer, int width, int height, int cx, int cy, int r,
                      float start_angle, float stop_angle, uint8_t color)
{
  if (r <= 0) return;

  float span = stop_angle - start_angle;
  if (span == 0.0f) return;

  int segments = arc_segments(r, span);
  float da = span / segments;
  float a = start_angle;

  for (int i = 0; i < segments; i++) {
    int x0 = cx + (int)(r * cosf(a) + 0.5f);
    int y0 = cy + (int)(r * sinf(a) + 0.5f);
    float a1 = a + da;
    int x1 = cx + (int)(r * cosf(a1) + 0.5f);
    int y1 = cy + (int)(r * sinf(a1) + 0.5f);
    dvi_graphics_fill_triangle(framebuffer, width, height, cx, cy, x0, y0, x1, y1, color);
    a = a1;
  }
}

void
dvi_graphics_draw_arc(uint8_t *framebuffer, int width, int height, int cx, int cy, int r,
                      float start_angle, float stop_angle, uint8_t color)
{
  if (r <= 0) return;

  float span = stop_angle - start_angle;
  if (span == 0.0f) return;

  int blending = (blend_mode != DVI_BLEND_REPLACE);
  int segments = arc_segments(r, span);
  float da = span / segments;
  float a = start_angle;
  int px = cx + (int)(r * cosf(a) + 0.5f);
  int py = cy + (int)(r * sinf(a) + 0.5f);

  for (int i = 0; i < segments; i++) {
    a += da;
    int nx = cx + (int)(r * cosf(a) + 0.5f);
    int ny = cy + (int)(r * sinf(a) + 0.5f);
    DRAW_PIXEL(framebuffer, width, height, px, py, color);
    // Use draw_line directly for outline segments
    dvi_graphics_draw_line(framebuffer, width, height, px, py, nx, ny, color);
    px = nx;
    py = ny;
  }
}

void
dvi_graphics_draw_thick_line(uint8_t *framebuffer, int width, int height, int x0, int y0, int x1,
                             int y1, int thickness, uint8_t color)
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
      dvi_graphics_draw_line(framebuffer, width, height, x0, y0 + i, x1, y1 + i, color);
  } else {
    // More vertical: offset in x
    for (int i = -half; i < thickness - half; i++)
      dvi_graphics_draw_line(framebuffer, width, height, x0 + i, y0, x1 + i, y1, color);
  }
}

void
dvi_graphics_draw_image(uint8_t *framebuffer, int width, int height, const uint8_t *data, int x,
                        int y, int image_width, int image_height)
{
  // Compute visible source region after clipping
  int src_x = 0, src_y = 0;
  int dst_x = x, dst_y = y;
  int draw_w = image_width, draw_h = image_height;

  if (dst_x < 0) {
    src_x = -dst_x;
    draw_w += dst_x;
    dst_x = 0;
  }
  if (dst_y < 0) {
    src_y = -dst_y;
    draw_h += dst_y;
    dst_y = 0;
  }
  if (dst_x + draw_w > width) draw_w = width - dst_x;
  if (dst_y + draw_h > height) draw_h = height - dst_y;
  if (draw_w <= 0 || draw_h <= 0) return;

  for (int row = 0; row < draw_h; row++) {
    memcpy(&framebuffer[(dst_y + row) * width + dst_x], &data[(src_y + row) * image_width + src_x],
           draw_w);
  }
}

void
dvi_graphics_draw_image_masked(uint8_t *framebuffer, int width, int height, const uint8_t *data,
                               const uint8_t *mask, int x, int y, int image_width, int image_height)
{
  // Compute visible source region after clipping
  int src_x = 0, src_y = 0;
  int dst_x = x, dst_y = y;
  int draw_w = image_width, draw_h = image_height;

  if (dst_x < 0) {
    src_x = -dst_x;
    draw_w += dst_x;
    dst_x = 0;
  }
  if (dst_y < 0) {
    src_y = -dst_y;
    draw_h += dst_y;
    dst_y = 0;
  }
  if (dst_x + draw_w > width) draw_w = width - dst_x;
  if (dst_y + draw_h > height) draw_h = height - dst_y;
  if (draw_w <= 0 || draw_h <= 0) return;

  for (int row = 0; row < draw_h; row++) {
    for (int col = 0; col < draw_w; col++) {
      int si = (src_y + row) * image_width + (src_x + col);
      int mask_byte = si >> 3;
      int mask_bit = si & 7;
      if (!(mask[mask_byte] & (1 << mask_bit))) continue;
      framebuffer[(dst_y + row) * width + (dst_x + col)] = data[si];
    }
  }
}

// Compute the axis-aligned bounding box of the four transformed corners,
// clamp to framebuffer bounds, and compute the inverse 2x2 matrix.
// The affine matrix maps source pixel (col, row) to screen:
//   screen_x = m00 * col + m01 * row + tx
//   screen_y = m10 * col + m11 * row + ty

static void image_affine_bounds(int image_width, int image_height,
                                int origin_x, int origin_y,
                                float m00, float m01, float m10, float m11,
                                float tx, float ty,
                                int fb_width, int fb_height,
                                int *out_min_x, int *out_min_y,
                                int *out_max_x, int *out_max_y,
                                float *out_inv00, float *out_inv01,
                                float *out_inv10, float *out_inv11,
                                float *out_etx, float *out_ety)
{
    // Effective translation: maps source pixel (0, 0) to screen
    float etx = m00 * origin_x + m01 * origin_y + tx;
    float ety = m10 * origin_x + m11 * origin_y + ty;

    // Four corners: (0,0), (w,0), (w,h), (0,h) mapped to screen
    float cx[4], cy[4];
    cx[0] = etx;
    cy[0] = ety;
    cx[1] = m00 * image_width + etx;
    cy[1] = m10 * image_width + ety;
    cx[2] = m00 * image_width + m01 * image_height + etx;
    cy[2] = m10 * image_width + m11 * image_height + ety;
    cx[3] = m01 * image_height + etx;
    cy[3] = m11 * image_height + ety;

    float min_x = cx[0], min_y = cy[0], max_x = cx[0], max_y = cy[0];
    for (int i = 1; i < 4; i++) {
        if (cx[i] < min_x) min_x = cx[i];
        if (cx[i] > max_x) max_x = cx[i];
        if (cy[i] < min_y) min_y = cy[i];
        if (cy[i] > max_y) max_y = cy[i];
    }

    *out_min_x = (int)floorf(min_x);
    *out_min_y = (int)floorf(min_y);
    *out_max_x = (int)ceilf(max_x);
    *out_max_y = (int)ceilf(max_y);

    if (*out_min_x < 0) *out_min_x = 0;
    if (*out_min_y < 0) *out_min_y = 0;
    if (*out_max_x > fb_width)  *out_max_x = fb_width;
    if (*out_max_y > fb_height) *out_max_y = fb_height;

    // Inverse of 2x2 part: [m00 m01; m10 m11]
    float det = m00 * m11 - m01 * m10;
    float inv_det = 1.0f / det;
    *out_inv00 =  m11 * inv_det;
    *out_inv01 = -m01 * inv_det;
    *out_inv10 = -m10 * inv_det;
    *out_inv11 =  m00 * inv_det;
    *out_etx = etx;
    *out_ety = ety;
}

void dvi_graphics_draw_image_affine(uint8_t *framebuffer, int fb_width, int fb_height,
                                    const uint8_t *data,
                                    int image_width, int image_height,
                                    int origin_x, int origin_y,
                                    float m00, float m01, float m10, float m11,
                                    float tx, float ty)
{
    int dst_min_x, dst_min_y, dst_max_x, dst_max_y;
    float inv00, inv01, inv10, inv11, etx, ety;
    image_affine_bounds(image_width, image_height, origin_x, origin_y,
                        m00, m01, m10, m11, tx, ty,
                        fb_width, fb_height,
                        &dst_min_x, &dst_min_y, &dst_max_x, &dst_max_y,
                        &inv00, &inv01, &inv10, &inv11, &etx, &ety);

    for (int dy = dst_min_y; dy < dst_max_y; dy++) {
        float ry = dy - ety + 0.5f;
        for (int dx = dst_min_x; dx < dst_max_x; dx++) {
            float rx = dx - etx + 0.5f;
            int sx = (int)floorf(inv00 * rx + inv01 * ry);
            int sy = (int)floorf(inv10 * rx + inv11 * ry);
            if (sx < 0 || sx >= image_width || sy < 0 || sy >= image_height)
                continue;
            framebuffer[dy * fb_width + dx] = data[sy * image_width + sx];
        }
    }
}

void dvi_graphics_draw_image_masked_affine(uint8_t *framebuffer, int fb_width, int fb_height,
                                           const uint8_t *data, const uint8_t *mask,
                                           int image_width, int image_height,
                                           int origin_x, int origin_y,
                                           float m00, float m01, float m10, float m11,
                                           float tx, float ty)
{
    int dst_min_x, dst_min_y, dst_max_x, dst_max_y;
    float inv00, inv01, inv10, inv11, etx, ety;
    image_affine_bounds(image_width, image_height, origin_x, origin_y,
                        m00, m01, m10, m11, tx, ty,
                        fb_width, fb_height,
                        &dst_min_x, &dst_min_y, &dst_max_x, &dst_max_y,
                        &inv00, &inv01, &inv10, &inv11, &etx, &ety);

    for (int dy = dst_min_y; dy < dst_max_y; dy++) {
        float ry = dy - ety + 0.5f;
        for (int dx = dst_min_x; dx < dst_max_x; dx++) {
            float rx = dx - etx + 0.5f;
            int sx = (int)floorf(inv00 * rx + inv01 * ry);
            int sy = (int)floorf(inv10 * rx + inv11 * ry);
            if (sx < 0 || sx >= image_width || sy < 0 || sy >= image_height)
                continue;
            int si = sy * image_width + sx;
            if (!(mask[si >> 3] & (1 << (si & 7))))
                continue;
            framebuffer[dy * fb_width + dx] = data[si];
        }
    }
}
