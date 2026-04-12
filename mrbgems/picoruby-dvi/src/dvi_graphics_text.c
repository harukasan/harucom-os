// Text rendering functions for DVI graphics mode.
// Separated from dvi_graphics_draw.c for maintainability.

#include <stdint.h>
#include <stddef.h>
#include <math.h>

#define DVI_FONT_REGISTRY_IMPLEMENTATION
#include "dvi_graphics_draw.h"
#include "dvi_graphics_internal.h"
#include "uni2jis_table.h"

const dvi_font_t *
dvi_graphics_get_font(int font_id)
{
  if (font_id < 0 || font_id >= (int)DVI_GRAPHICS_FONT_COUNT) return NULL;
  return graphics_fonts[font_id];
}

int
dvi_graphics_font_height(int font_id)
{
  const dvi_font_t *font = dvi_graphics_get_font(font_id);
  if (!font) return 0;
  return font->glyph_height;
}

// Decode one UTF-8 codepoint from *p, advance *p past consumed bytes.
// Returns the codepoint, or -1 on invalid sequence.
static int32_t
utf8_decode(const char **p)
{
  const uint8_t *s = (const uint8_t *)*p;
  int32_t cp;
  int len;

  if (s[0] < 0x80) {
    cp = s[0];
    len = 1;
  } else if ((s[0] & 0xE0) == 0xC0) {
    cp = s[0] & 0x1F;
    len = 2;
  } else if ((s[0] & 0xF0) == 0xE0) {
    cp = s[0] & 0x0F;
    len = 3;
  } else if ((s[0] & 0xF8) == 0xF0) {
    cp = s[0] & 0x07;
    len = 4;
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
static int
unicode_to_jis_index(int32_t cp)
{
  uint16_t jis = uni2jis_lookup(cp);
  if (jis == 0) return -1;
  int ku = (jis >> 8) - 0x20;
  int ten = (jis & 0xFF) - 0x20;
  return (ku - 1) * 94 + (ten - 1);
}

// Compute the byte offset for glyph at index idx.
static inline int
glyph_offset(const dvi_font_t *font, int idx)
{
  if (font->glyph_stride) return idx * font->glyph_stride;
  int bytes_per_row = (font->glyph_width + 7) / 8;
  return idx * bytes_per_row * font->glyph_height;
}

// Compute the advance width of a character without rendering.
static int
char_advance(int32_t cp, const dvi_font_t *font, const dvi_font_t *wide_font)
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
static inline uint8_t
blend_aa_pixel(uint8_t bg, uint8_t fg, uint8_t alpha4)
{
  int a = alpha4 * 17; // map 0-15 to 0-255
  int inv_a = 255 - a;
  int sr = (fg >> 5) & 7, sg = (fg >> 2) & 7, sb = fg & 3;
  int dr = (bg >> 5) & 7, dg = (bg >> 2) & 7, db = bg & 3;
  int rr = (sr * a + dr * inv_a) / 255;
  int rg = (sg * a + dg * inv_a) / 255;
  int rb = (sb * a + db * inv_a) / 255;
  return (uint8_t)((rr << 5) | (rg << 2) | rb);
}

// Render one 4bpp anti-aliased glyph at (char_x, y) and return its advance width.
static int
draw_glyph_4bpp(uint8_t *framebuffer, int fb_width, int fb_height, int char_x, int y, int idx,
                uint8_t color, const dvi_font_t *font)
{
  int gw = font->glyph_width;
  int gh = font->glyph_height;
  int bytes_per_row = (gw + 1) / 2;
  const uint8_t *glyph = &font->bitmap[glyph_offset(font, idx)];

  for (int row = 0; row < gh; row++) {
    int py = y + row;
    if (py < 0) continue;
    if (py >= fb_height) break;

    const uint8_t *row_data = &glyph[row * bytes_per_row];
    for (int col = 0; col < gw; col++) {
      uint8_t byte_val = row_data[col / 2];
      uint8_t v = (col & 1) ? (byte_val & 0x0F) : (byte_val >> 4);
      if (v == 0) continue;
      int px = char_x + font->bitmap_left + col;
      if (px < 0) continue;
      if (px >= fb_width) break;
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
static int
draw_glyph(uint8_t *framebuffer, int fb_width, int fb_height, int char_x, int y, int idx,
           uint8_t color, const dvi_font_t *font)
{
  int gw = font->glyph_width;
  int gh = font->glyph_height;
  int bytes_per_row = (gw + 7) / 8;
  const uint8_t *glyph = &font->bitmap[glyph_offset(font, idx)];

  for (int row = 0; row < gh; row++) {
    int py = y + row;
    if (py < 0) continue;
    if (py >= fb_height) break;

    for (int col = 0; col < gw; col++) {
      int byte_idx = col / 8;
      int bit_idx = 7 - (col % 8);
      if (!(glyph[row * bytes_per_row + byte_idx] & (1 << bit_idx))) continue;
      int px = char_x + col;
      if (px < 0) continue;
      if (px >= fb_width) break;
      dvi_graphics_write_pixel(framebuffer, py * fb_width + px, color);
    }
  }

  return (font->widths) ? font->widths[idx] : gw;
}

void
dvi_graphics_draw_text(uint8_t *framebuffer, int width, int height, int x, int y, const char *text,
                       uint8_t color, const dvi_font_t *font, const dvi_font_t *wide_font)
{
  int gw = font->glyph_width;
  int first = font->first_char;
  int num = font->num_chars;
  int char_x = x;

  const char *p = text;
  while (*p) {
    int32_t cp = utf8_decode(&p);
    if (cp < 0) continue;

    if (char_x >= width) break;

    // Try primary font
    int idx = cp - first;
    if (idx >= 0 && idx < num) {
      int advance = (font->widths) ? font->widths[idx] : gw;
      if (char_x + advance > 0) {
        if (font->bpp == 4)
          draw_glyph_4bpp(framebuffer, width, height, char_x, y, idx, color, font);
        else
          draw_glyph(framebuffer, width, height, char_x, y, idx, color, font);
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
            draw_glyph_4bpp(framebuffer, width, height, char_x, y, jis_idx, color, wide_font);
          else
            draw_glyph(framebuffer, width, height, char_x, y, jis_idx, color, wide_font);
        }
        char_x += advance;
        continue;
      }
    }

    // Unknown character: advance by primary font width
    char_x += gw;
  }
}

int
dvi_graphics_text_width(const char *text, const dvi_font_t *font, const dvi_font_t *wide_font)
{
  int total = 0;
  const char *p = text;
  while (*p) {
    int32_t cp = utf8_decode(&p);
    if (cp < 0) continue;
    total += char_advance(cp, font, wide_font);
  }
  return total;
}

// Sample the text glyph bitmap at virtual image coordinate (sx, sy).
// The virtual image is the text rendered horizontally: width = text_width, height = font_height.
// Returns the pixel value: for 4bpp fonts, a 4-bit alpha (0-15); for 1bpp, 0 or 1.
// glyph_x_offsets is a pre-built table mapping each virtual x to a glyph.
//
// To avoid a per-pixel linear scan through glyphs, the caller pre-builds
// arrays that map each virtual x-column to its glyph index and local column.
// This trades O(text_width) memory for O(1) lookup per pixel.

// Per-glyph info for affine text rendering.
typedef struct {
    const uint8_t *bitmap;    // glyph bitmap pointer
    int width;                // glyph width in pixels
    int bitmap_left;          // left bearing (4bpp fonts)
    int bpp;                  // 1 or 4
    int bytes_per_row;        // row stride in bytes
} text_affine_glyph_t;

// Sample one pixel from the virtual text image.
// glyph_for_x[sx] gives the glyph index, glyph_col_for_x[sx] gives the column within that glyph.
static inline int sample_text_pixel(int sx, int sy,
                                    const int *glyph_for_x,
                                    const int *glyph_col_for_x,
                                    const text_affine_glyph_t *glyphs,
                                    int text_height)
{
    if (sy < 0 || sy >= text_height)
        return 0;
    int gi = glyph_for_x[sx];
    if (gi < 0)
        return 0;
    const text_affine_glyph_t *g = &glyphs[gi];
    int col = glyph_col_for_x[sx] - g->bitmap_left;
    if (col < 0 || col >= g->width)
        return 0;
    if (g->bpp == 4) {
        int byte_val = g->bitmap[sy * g->bytes_per_row + col / 2];
        return (col & 1) ? (byte_val & 0x0F) : (byte_val >> 4);
    } else {
        int byte_idx = col / 8;
        int bit_idx = 7 - (col % 8);
        return (g->bitmap[sy * g->bytes_per_row + byte_idx] & (1 << bit_idx)) ? 1 : 0;
    }
}

#define MAX_TEXT_AFFINE_GLYPHS 128
#define MAX_TEXT_AFFINE_WIDTH 640

void dvi_graphics_draw_text_affine(uint8_t *framebuffer, int fb_width, int fb_height,
                                   const char *text, uint8_t color,
                                   const dvi_font_t *font, const dvi_font_t *wide_font,
                                   int origin_x, int origin_y,
                                   float m00, float m01, float m10, float m11,
                                   float tx, float ty)
{
    int text_height = font->glyph_height;

    // Build per-glyph table
    text_affine_glyph_t glyphs[MAX_TEXT_AFFINE_GLYPHS];
    int glyph_starts[MAX_TEXT_AFFINE_GLYPHS]; // x offset of each glyph
    int num_glyphs = 0;
    int text_width = 0;

    const char *p = text;
    while (*p && num_glyphs < MAX_TEXT_AFFINE_GLYPHS) {
        int32_t cp = utf8_decode(&p);
        if (cp < 0)
            continue;

        const dvi_font_t *use_font = NULL;
        int idx = -1;

        // Try primary font
        int pidx = cp - font->first_char;
        if (pidx >= 0 && pidx < font->num_chars) {
            use_font = font;
            idx = pidx;
        }
        // Try wide font
        if (!use_font && wide_font) {
            int jis_idx = unicode_to_jis_index(cp);
            if (jis_idx >= 0 && jis_idx < wide_font->num_chars) {
                use_font = wide_font;
                idx = jis_idx;
            }
        }

        int advance = char_advance(cp, font, wide_font);
        if (use_font && idx >= 0) {
            text_affine_glyph_t *g = &glyphs[num_glyphs];
            g->bitmap = &use_font->bitmap[glyph_offset(use_font, idx)];
            g->width = use_font->glyph_width;
            g->bitmap_left = (use_font->bpp == 4) ? use_font->bitmap_left : 0;
            g->bpp = use_font->bpp;
            g->bytes_per_row = (use_font->bpp == 4)
                ? (use_font->glyph_width + 1) / 2
                : (use_font->glyph_width + 7) / 8;
            glyph_starts[num_glyphs] = text_width;
            num_glyphs++;
        }
        text_width += advance;
    }

    if (text_width <= 0 || text_width > MAX_TEXT_AFFINE_WIDTH)
        return;

    // Build x-to-glyph lookup tables
    int glyph_for_x[MAX_TEXT_AFFINE_WIDTH];
    int glyph_col_for_x[MAX_TEXT_AFFINE_WIDTH];
    {
        int gi = 0;
        int next_start = (num_glyphs > 1) ? glyph_starts[1] : text_width;
        for (int x = 0; x < text_width; x++) {
            while (gi + 1 < num_glyphs && x >= next_start) {
                gi++;
                next_start = (gi + 1 < num_glyphs) ? glyph_starts[gi + 1] : text_width;
            }
            if (x >= glyph_starts[gi] && gi < num_glyphs) {
                glyph_for_x[x] = gi;
                glyph_col_for_x[x] = x - glyph_starts[gi];
            } else {
                glyph_for_x[x] = -1;
                glyph_col_for_x[x] = 0;
            }
        }
    }

    // Compute bounding box using the same approach as image_affine
    float etx = m00 * origin_x + m01 * origin_y + tx;
    float ety = m10 * origin_x + m11 * origin_y + ty;

    float cx[4], cy[4];
    cx[0] = etx;                                                      cy[0] = ety;
    cx[1] = m00 * text_width + etx;                                   cy[1] = m10 * text_width + ety;
    cx[2] = m00 * text_width + m01 * text_height + etx;               cy[2] = m10 * text_width + m11 * text_height + ety;
    cx[3] = m01 * text_height + etx;                                  cy[3] = m11 * text_height + ety;

    float fmin_x = cx[0], fmin_y = cy[0], fmax_x = cx[0], fmax_y = cy[0];
    for (int i = 1; i < 4; i++) {
        if (cx[i] < fmin_x) fmin_x = cx[i];
        if (cx[i] > fmax_x) fmax_x = cx[i];
        if (cy[i] < fmin_y) fmin_y = cy[i];
        if (cy[i] > fmax_y) fmax_y = cy[i];
    }

    int dst_min_x = (int)floorf(fmin_x);
    int dst_min_y = (int)floorf(fmin_y);
    int dst_max_x = (int)ceilf(fmax_x);
    int dst_max_y = (int)ceilf(fmax_y);
    if (dst_min_x < 0) dst_min_x = 0;
    if (dst_min_y < 0) dst_min_y = 0;
    if (dst_max_x > fb_width)  dst_max_x = fb_width;
    if (dst_max_y > fb_height) dst_max_y = fb_height;

    // Inverse 2x2 matrix
    float det = m00 * m11 - m01 * m10;
    float inv_det = 1.0f / det;
    float inv00 =  m11 * inv_det;
    float inv01 = -m01 * inv_det;
    float inv10 = -m10 * inv_det;
    float inv11 =  m00 * inv_det;

    // Check if any glyph uses 4bpp (for blending)
    int has_4bpp = 0;
    for (int i = 0; i < num_glyphs; i++) {
        if (glyphs[i].bpp == 4) {
            has_4bpp = 1;
            break;
        }
    }

    // Render loop: iterate over screen pixels in bounding box
    for (int dy = dst_min_y; dy < dst_max_y; dy++) {
        float ry = dy - ety + 0.5f;
        for (int dx = dst_min_x; dx < dst_max_x; dx++) {
            float rx = dx - etx + 0.5f;
            int sx = (int)floorf(inv00 * rx + inv01 * ry);
            int sy = (int)floorf(inv10 * rx + inv11 * ry);
            if (sx < 0 || sx >= text_width || sy < 0 || sy >= text_height)
                continue;
            int v = sample_text_pixel(sx, sy, glyph_for_x, glyph_col_for_x,
                                      glyphs, text_height);
            if (v == 0)
                continue;
            int offset = dy * fb_width + dx;
            if (has_4bpp) {
                if (v >= 15)
                    framebuffer[offset] = color;
                else
                    framebuffer[offset] = blend_aa_pixel(framebuffer[offset], color, v);
            } else {
                dvi_graphics_write_pixel(framebuffer, offset, color);
            }
        }
    }
}
