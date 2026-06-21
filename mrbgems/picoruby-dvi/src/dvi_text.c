// Platform-independent text-mode core for DVI: cell VRAM writers, the narrow
// font cache and the 16-color palette. Shared by the RP2350 HSTX/DMA renderer
// and the browser canvas renderer (see include/dvi_text_internal.h).

#include <string.h>

#include "dvi.h"
#include "dvi_text_internal.h"
#include "uni2jis_table.h"

// Text-mode grid is sized from the native 640x480 surface.
#define TEXT_ACTIVE_WIDTH  DVI_GRAPHICS_MAX_WIDTH  // 640
#define TEXT_ACTIVE_HEIGHT DVI_GRAPHICS_MAX_HEIGHT // 480

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

int dvi_text_cols = DVI_TEXT_MAX_COLS;
int dvi_text_rows = DVI_TEXT_MAX_ROWS;
static uint8_t text_palette[16];
uint32_t dvi_text_palette32[16];
static const dvi_font_t *text_font;
static const dvi_font_t *text_wide_font;
uint8_t dvi_text_narrow_cache[TEXT_GLYPH_HEIGHT_12WIDE * NARROW_CACHE_STRIDE];

dvi_text_cell_t *dvi_text_write_vram;
uint8_t *dvi_text_write_row_has_wide;
int dvi_text_write_scroll_offset = 0;
uint8_t *dvi_text_glyph_bitmap;

// Default 16-color palette (RGB332, ANSI color order).
static const uint8_t default_palette[16] = {
    0x00, // 0  Black
    0xE0, // 1  Red
    0x1C, // 2  Green
    0xA8, // 3  Brown
    0x03, // 4  Blue
    0xE3, // 5  Magenta
    0x1F, // 6  Cyan
    0xB6, // 7  Light Gray
    0x49, // 8  Dark Gray
    0xF0, // 9  Orange
    0x7C, // 10 Lime
    0xFC, // 11 Yellow
    0x17, // 12 Sky Blue
    0xEA, // 13 Pink
    0x5F, // 14 Bright Cyan
    0xFF, // 15 White
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void
update_palette32(void)
{
  for (int i = 0; i < 16; i++)
    dvi_text_palette32[i] = text_palette[i] * 0x01010101u;
}

int
dvi_text_physical_row(int logical_row, int offset)
{
  int r = logical_row + offset;
  return r >= dvi_text_rows ? r - dvi_text_rows : r;
}

void
dvi_text_render_wide_glyph(int col, int phys_row, uint16_t linear_jis,
                           const dvi_font_t *font, bool bold)
{
  if (!font) return;
  int bytes_per_glyph = font->glyph_height * 2;
  int stride = bytes_per_glyph * 2;
  const uint8_t *src = font->bitmap + (linear_jis - font->first_char) * stride;
  if (bold) src += bytes_per_glyph;
  for (int y = 0; y < font->glyph_height; y++) {
    int base = (phys_row * TEXT_GLYPH_HEIGHT_12WIDE + y) * GLYPH_BITMAP_STRIDE + col;
    dvi_text_glyph_bitmap[base] = src[y * 2];
    dvi_text_glyph_bitmap[base + 1] = src[y * 2 + 1];
  }
}

// Decode one UTF-8 character; store the codepoint in *cp; return next pointer.
static const char *
utf8_decode(const char *str, uint32_t *cp)
{
  uint8_t b = (uint8_t)*str;
  if (b < 0x80) {
    *cp = b;
    return str + 1;
  } else if ((b & 0xE0) == 0xC0) {
    *cp = (b & 0x1F) << 6 | ((uint8_t)str[1] & 0x3F);
    return str + 2;
  } else if ((b & 0xF0) == 0xE0) {
    *cp = (b & 0x0F) << 12 | ((uint8_t)str[1] & 0x3F) << 6 | ((uint8_t)str[2] & 0x3F);
    return str + 3;
  } else if ((b & 0xF8) == 0xF0) {
    *cp = (b & 0x07) << 18 | ((uint8_t)str[1] & 0x3F) << 12 |
          ((uint8_t)str[2] & 0x3F) << 6 | ((uint8_t)str[3] & 0x3F);
    return str + 4;
  }
  *cp = '?';
  return str + 1;
}

static inline uint16_t
unicode_to_jis(uint32_t cp)
{
  return uni2jis_lookup(cp);
}

static void
clear_physical_line(int phys, uint8_t attr)
{
  dvi_text_cell_t *line = &dvi_text_write_vram[phys * dvi_text_cols];
  for (int i = 0; i < dvi_text_cols; i++) {
    line[i].ch = ' ';
    line[i].attr = attr;
    line[i].flags = 0;
  }
  dvi_text_write_row_has_wide[phys] = 0;
}

// ---------------------------------------------------------------------------
// Initialization helpers (called by the platform during text-mode setup)
// ---------------------------------------------------------------------------

void
dvi_text_init_palette(void)
{
  memcpy(text_palette, default_palette, sizeof(default_palette));
  update_palette32();
}

// ---------------------------------------------------------------------------
// Font cache
// ---------------------------------------------------------------------------

void
dvi_text_set_font(const dvi_font_t *font)
{
  text_font = font;
  dvi_text_cols = TEXT_ACTIVE_WIDTH / font->glyph_width;
  dvi_text_rows = (TEXT_ACTIVE_HEIGHT + font->glyph_height - 1) / font->glyph_height;
  if (dvi_text_cols > DVI_TEXT_MAX_COLS) dvi_text_cols = DVI_TEXT_MAX_COLS;
  if (dvi_text_rows > DVI_TEXT_MAX_ROWS) dvi_text_rows = DVI_TEXT_MAX_ROWS;

  // Build row-major SRAM cache (regular region 0-255) from column-major font.
  if (font->glyph_height <= TEXT_GLYPH_HEIGHT_12WIDE) {
    const uint8_t *src = font->bitmap;
    int first = font->first_char;
    int num = font->num_chars;
    int gh = font->glyph_height;
    memset(dvi_text_narrow_cache, 0, sizeof(dvi_text_narrow_cache));
    for (int ch = 0; ch < num; ch++) {
      for (int y = 0; y < gh; y++) {
        dvi_text_narrow_cache[y * NARROW_CACHE_STRIDE + (first + ch)] = src[ch * gh + y];
      }
    }
  }
}

void
dvi_text_set_wide_font(const dvi_font_t *font)
{
  text_wide_font = font;
}

void
dvi_text_set_bold_font(const dvi_font_t *font)
{
  if (font && font->glyph_height <= TEXT_GLYPH_HEIGHT_12WIDE) {
    const uint8_t *src = font->bitmap;
    int first = font->first_char;
    int num = font->num_chars;
    int gh = font->glyph_height;
    // Build bold region (offset 256-511) of the 512-stride cache.
    for (int y = 0; y < gh; y++)
      memset(&dvi_text_narrow_cache[y * NARROW_CACHE_STRIDE + 256], 0, 256);
    for (int ch = 0; ch < num; ch++) {
      for (int y = 0; y < gh; y++) {
        dvi_text_narrow_cache[y * NARROW_CACHE_STRIDE + 256 + (first + ch)] = src[ch * gh + y];
      }
    }
  }
}

int
dvi_text_get_cols(void)
{
  return dvi_text_cols;
}

int
dvi_text_get_rows(void)
{
  return dvi_text_rows;
}

dvi_text_cell_t *
dvi_get_text_vram(void)
{
  return dvi_text_write_vram;
}

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

void
dvi_text_set_palette(const uint8_t palette[16])
{
  memcpy(text_palette, palette, 16);
  update_palette32();
}

void
dvi_text_set_palette_entry(int index, uint8_t color)
{
  if (index < 0 || index >= 16) return;
  text_palette[index] = color;
  update_palette32();
}

uint8_t
dvi_text_get_palette_entry(int index)
{
  if (index < 0 || index >= 16) return 0;
  return text_palette[index];
}

// ---------------------------------------------------------------------------
// Cell writers
// ---------------------------------------------------------------------------

void
dvi_text_put_char(int col, int row, char ch, uint8_t attr)
{
  if (col < 0 || col >= dvi_text_cols || row < 0 || row >= dvi_text_rows) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  dvi_text_cell_t *c = &dvi_text_write_vram[phys * dvi_text_cols + col];
  c->ch = (uint8_t)ch;
  c->attr = attr;
  c->flags = 0;
}

void
dvi_text_put_char_bold(int col, int row, char ch, uint8_t attr)
{
  if (col < 0 || col >= dvi_text_cols || row < 0 || row >= dvi_text_rows) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  dvi_text_cell_t *c = &dvi_text_write_vram[phys * dvi_text_cols + col];
  c->ch = (uint8_t)ch | 0x100; // bit 8 = bold indicator for 512-stride cache
  c->attr = attr;
  c->flags = DVI_CELL_FLAG_BOLD;
}

void
dvi_text_put_wide_char(int col, int row, uint16_t ch, uint8_t attr)
{
  if (col < 0 || col + 1 >= dvi_text_cols || row < 0 || row >= dvi_text_rows) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  dvi_text_render_wide_glyph(col, phys, ch, text_wide_font, false);
  dvi_text_cell_t *left = &dvi_text_write_vram[phys * dvi_text_cols + col];
  dvi_text_cell_t *right = &dvi_text_write_vram[phys * dvi_text_cols + col + 1];
  left->ch = ch; // linear JIS index (used by write_line for re-rendering)
  left->attr = attr;
  left->flags = DVI_CELL_FLAG_WIDE_L;
  right->ch = 0;
  right->attr = attr;
  right->flags = DVI_CELL_FLAG_WIDE_R;
  dvi_text_write_row_has_wide[phys] = 1;
}

void
dvi_text_put_wide_char_bold(int col, int row, uint16_t ch, uint8_t attr)
{
  if (col < 0 || col + 1 >= dvi_text_cols || row < 0 || row >= dvi_text_rows) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  dvi_text_render_wide_glyph(col, phys, ch, text_wide_font, true);
  dvi_text_cell_t *left = &dvi_text_write_vram[phys * dvi_text_cols + col];
  dvi_text_cell_t *right = &dvi_text_write_vram[phys * dvi_text_cols + col + 1];
  left->ch = ch; // linear JIS index
  left->attr = attr;
  left->flags = DVI_CELL_FLAG_WIDE_L | DVI_CELL_FLAG_BOLD;
  right->ch = 0;
  right->attr = attr;
  right->flags = DVI_CELL_FLAG_WIDE_R | DVI_CELL_FLAG_BOLD;
  dvi_text_write_row_has_wide[phys] = 1;
}

// Shared body for put_string / put_string_bold: lay out a UTF-8 string into
// cells, wrapping at the right edge and on '\n', mapping non-ASCII through JIS
// to full-width glyphs (falling back to '?' when unmapped). The bold flag picks
// the bold cell writers; this is a set-time path, so the extra branch has no
// effect on render timing.
static void
put_string_internal(int col, int row, const char *str, uint8_t attr, bool bold)
{
  int start_col = col;
  while (*str && row < dvi_text_rows) {
    uint32_t cp;
    str = utf8_decode(str, &cp);

    if (cp == '\n') {
      col = start_col;
      row++;
      continue;
    }

    if (cp < 0x80) {
      if (col >= dvi_text_cols) {
        col = start_col;
        row++;
        if (row >= dvi_text_rows) break;
      }
      if (bold) dvi_text_put_char_bold(col, row, (char)cp, attr);
      else      dvi_text_put_char(col, row, (char)cp, attr);
      col++;
    } else {
      uint16_t jis = unicode_to_jis(cp);
      if (jis) {
        if (col + 1 >= dvi_text_cols) {
          col = start_col;
          row++;
          if (row >= dvi_text_rows) break;
        }
        if (bold) dvi_text_put_wide_char_bold(col, row, dvi_jis_to_linear(jis), attr);
        else      dvi_text_put_wide_char(col, row, dvi_jis_to_linear(jis), attr);
        col += 2;
      } else {
        if (col >= dvi_text_cols) {
          col = start_col;
          row++;
          if (row >= dvi_text_rows) break;
        }
        if (bold) dvi_text_put_char_bold(col, row, '?', attr);
        else      dvi_text_put_char(col, row, '?', attr);
        col++;
      }
    }
  }
}

void
dvi_text_put_string(int col, int row, const char *str, uint8_t attr)
{
  put_string_internal(col, row, str, attr, false);
}

void
dvi_text_put_string_bold(int col, int row, const char *str, uint8_t attr)
{
  put_string_internal(col, row, str, attr, true);
}

// ---------------------------------------------------------------------------
// Screen management
// ---------------------------------------------------------------------------

void
dvi_text_clear(uint8_t attr)
{
  for (int i = 0; i < dvi_text_rows * dvi_text_cols; i++) {
    dvi_text_write_vram[i].ch = ' ';
    dvi_text_write_vram[i].attr = attr;
    dvi_text_write_vram[i].flags = 0;
  }
  memset(dvi_text_write_row_has_wide, 0, dvi_text_rows);
  dvi_text_write_scroll_offset = 0;
}

void
dvi_text_clear_line(int row, uint8_t attr)
{
  if (row < 0 || row >= dvi_text_rows) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  clear_physical_line(phys, attr);
}

void
dvi_text_clear_range(int col, int row, int width, uint8_t attr)
{
  if (row < 0 || row >= dvi_text_rows) return;
  if (col < 0) {
    width += col;
    col = 0;
  }
  if (col + width > dvi_text_cols) width = dvi_text_cols - col;
  if (width <= 0) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  dvi_text_cell_t *line = &dvi_text_write_vram[phys * dvi_text_cols + col];
  for (int i = 0; i < width; i++) {
    line[i].ch = ' ';
    line[i].attr = attr;
    line[i].flags = 0;
  }
}

void
dvi_text_scroll_up(int lines, uint8_t fill_attr)
{
  if (lines <= 0) return;
  if (lines >= dvi_text_rows) {
    dvi_text_clear(fill_attr);
    return;
  }
  // Ring buffer: advance offset and clear the vacated rows.
  for (int i = 0; i < lines; i++) {
    int phys = dvi_text_physical_row(0, dvi_text_write_scroll_offset);
    clear_physical_line(phys, fill_attr);
    dvi_text_write_scroll_offset++;
    if (dvi_text_write_scroll_offset >= dvi_text_rows) dvi_text_write_scroll_offset -= dvi_text_rows;
  }
}

void
dvi_text_scroll_down(int lines, uint8_t fill_attr)
{
  if (lines <= 0) return;
  if (lines >= dvi_text_rows) {
    dvi_text_clear(fill_attr);
    return;
  }
  // Ring buffer: retreat offset and clear the vacated rows.
  for (int i = 0; i < lines; i++) {
    dvi_text_write_scroll_offset--;
    if (dvi_text_write_scroll_offset < 0) dvi_text_write_scroll_offset += dvi_text_rows;
    int phys = dvi_text_physical_row(0, dvi_text_write_scroll_offset);
    clear_physical_line(phys, fill_attr);
  }
}

uint8_t
dvi_text_get_attr(int col, int row)
{
  if (col < 0 || col >= dvi_text_cols || row < 0 || row >= dvi_text_rows) return 0;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  return dvi_text_write_vram[phys * dvi_text_cols + col].attr;
}

void
dvi_text_set_attr(int col, int row, uint8_t attr)
{
  if (col < 0 || col >= dvi_text_cols || row < 0 || row >= dvi_text_rows) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  dvi_text_write_vram[phys * dvi_text_cols + col].attr = attr;
}

void
dvi_text_read_line(int row, dvi_text_cell_t *dst)
{
  if (row < 0 || row >= dvi_text_rows || !dst) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  memcpy(dst, &dvi_text_write_vram[phys * dvi_text_cols], dvi_text_cols * sizeof(dvi_text_cell_t));
}

void
dvi_text_write_line(int row, const dvi_text_cell_t *src)
{
  if (row < 0 || row >= dvi_text_rows || !src) return;
  int phys = dvi_text_physical_row(row, dvi_text_write_scroll_offset);
  // Render wide glyphs before the VRAM update so the bitmap is ready when the
  // renderer sees the new cells.
  uint8_t has_wide = 0;
  for (int col = 0; col < dvi_text_cols; col++) {
    if (src[col].flags & DVI_CELL_FLAG_WIDE_L) {
      bool bold = src[col].flags & DVI_CELL_FLAG_BOLD;
      dvi_text_render_wide_glyph(col, phys, src[col].ch, text_wide_font, bold);
      has_wide = 1;
    }
  }
  memcpy(&dvi_text_write_vram[phys * dvi_text_cols], src, dvi_text_cols * sizeof(dvi_text_cell_t));
  dvi_text_write_row_has_wide[phys] = has_wide;
}
