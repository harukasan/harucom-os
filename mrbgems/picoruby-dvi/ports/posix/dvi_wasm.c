// Copyright (c) 2026 Shunsuke Michii
//
// Browser (emscripten) DVI port. Renders the shared text VRAM into an RGB332
// framebuffer that JavaScript blits to a canvas. It owns the VRAM, the
// wide-glyph bitmap, the framebuffer and the cell-to-pixel renderer, the wasm
// counterpart of the RP2350 HSTX/DMA scanline renderer.

#ifdef __EMSCRIPTEN__

#include <string.h>
#include <emscripten.h>

#include "dvi.h"
#include "dvi_text_internal.h"

// Text-mode fonts. Same generated headers the board uses (src/main.c).
#include "font_mplus_f12r.h"
#include "font_mplus_f12b.h"
#include "font_mplus_j12_combined.h"

#define FB_WIDTH  DVI_GRAPHICS_MAX_WIDTH
#define FB_HEIGHT DVI_GRAPHICS_MAX_HEIGHT

// Platform-owned buffers (single-buffered: the browser is single threaded).
static dvi_text_cell_t vram[DVI_TEXT_MAX_ROWS * DVI_TEXT_MAX_COLS];
static uint8_t row_has_wide[DVI_TEXT_MAX_ROWS];
static uint8_t glyph_bitmap[GLYPH_BITMAP_SIZE];
static uint8_t framebuffer[FB_WIDTH * FB_HEIGHT];

static dvi_mode_t active_mode = DVI_MODE_TEXT;
static uint32_t frame_count = 0;
static int graphics_scale = 1;

// Graphics drawing target at the logical resolution (640x480 at scale 1,
// 320x240 at scale 2). dvi_graphics_commit copies or upscales it into the
// displayed framebuffer.
static uint8_t graphics_buf[FB_WIDTH * FB_HEIGHT];

// ---------------------------------------------------------------------------
// Text renderer: VRAM cells -> RGB332 framebuffer.
// ---------------------------------------------------------------------------

static void
render_text(void)
{
  // The board draws the border in black.
  const uint8_t border_black = 0x00;

  // At text scale 2 the grid (53x18) is rendered into a 320x240 source image
  // and nearest-neighbor doubled to the 640x480 display, matching the board's
  // 2x scaled text mode. Scale 1 renders straight into the framebuffer.
  int scale = dvi_text_scale;
  int src_w = FB_WIDTH / scale;
  int src_h = FB_HEIGHT / scale;
  // One source scanline (src_w columns used). The extra slack absorbs a stray
  // full-width glyph in the last column, which emits 12px and can run a few
  // pixels past src_w (the board's line_buf carries the same margin).
  uint8_t line[FB_WIDTH + 8];

  for (int sy = 0; sy < src_h; sy++) {
    int text_row = sy / TEXT_GLYPH_HEIGHT_12WIDE;
    int glyph_y = sy % TEXT_GLYPH_HEIGHT_12WIDE;
    int x = 0;

    if (text_row >= dvi_text_rows) {
      memset(line, border_black, src_w);
    } else {
      int phys_row = dvi_text_physical_row(text_row, dvi_text_write_scroll_offset);
      // Fixed VRAM row stride (see dvi_text_internal.h): cells for row r live at
      // [phys_row * TEXT_VRAM_STRIDE + col] regardless of the active scale.
      const dvi_text_cell_t *row = &dvi_text_write_vram[phys_row * TEXT_VRAM_STRIDE];
      const uint8_t *nrow = dvi_text_narrow_cache + glyph_y * NARROW_CACHE_STRIDE;
      const uint8_t *grow = dvi_text_glyph_bitmap +
                            (phys_row * TEXT_GLYPH_HEIGHT_12WIDE + glyph_y) * GLYPH_BITMAP_STRIDE;

      for (int col = 0; col < dvi_text_cols; col++) {
        dvi_text_cell_t cell = row[col];
        uint8_t fg = (uint8_t)dvi_text_palette32[(cell.attr >> 4) & 0x0F];
        uint8_t bg = (uint8_t)dvi_text_palette32[cell.attr & 0x0F];

        if (cell.flags & (DVI_CELL_FLAG_WIDE_L | DVI_CELL_FLAG_WIDE_R)) {
          // Full-width: 12px from the glyph bitmap. b0 is cols 0-7, b1 is cols
          // 8-11, MSB-first. Then consume the partner cell.
          //
          // The board dispatches WIDE_L and WIDE_R together and skips two cells.
          // So a stray WIDE_R, whose WIDE_L half was overwritten by a half-width
          // char, must still render a 12px glyph and advance the row two cells,
          // not leave a 6px gap.
          uint8_t b0 = grow[col];
          uint8_t b1 = grow[col + 1];
          for (int px = 0; px < 8; px++) line[x++] = (b0 & (0x80 >> px)) ? fg : bg;
          for (int px = 0; px < 4; px++) line[x++] = (b1 & (0x80 >> px)) ? fg : bg;
          col++; // consume the partner cell
        } else {
          // Half-width: 6px from the narrow cache. Bold is encoded as ch|0x100,
          // indexing the upper (256-511) half of the cache row.
          uint8_t mask = nrow[cell.ch & 0x1FF];
          for (int px = 0; px < TEXT_GLYPH_WIDTH_12WIDE; px++)
            line[x++] = (mask & (0x80 >> px)) ? fg : bg;
        }
      }
      // Right margin past cols*6 stays black.
      while (x < src_w) line[x++] = border_black;
    }

    // Emit the source scanline, replicated `scale` times horizontally and
    // vertically into the displayed framebuffer.
    if (scale == 1) {
      memcpy(framebuffer + sy * FB_WIDTH, line, FB_WIDTH);
    } else {
      for (int v = 0; v < scale; v++) {
        uint8_t *out = framebuffer + (sy * scale + v) * FB_WIDTH;
        int ox = 0;
        for (int sx = 0; sx < src_w; sx++) {
          uint8_t px = line[sx];
          for (int h = 0; h < scale; h++) out[ox++] = px;
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Platform contract (the parts the RP2350 port keeps in dvi_output.c)
// ---------------------------------------------------------------------------

// Switch the displayed surface. No hardware VSync to defer to, so apply
// immediately. Switching to text repaints the VRAM; switching to graphics keeps
// the last frame until the first graphics commit.
void
dvi_set_mode(dvi_mode_t mode)
{
  if (mode == active_mode) return;
  active_mode = mode;
  if (mode == DVI_MODE_TEXT) {
    render_text();
    frame_count++;
  }
}

void dvi_set_blanking(bool enable) { (void)enable; }
uint8_t *dvi_get_framebuffer(void) { return graphics_buf; }
uint32_t dvi_get_frame_count(void) { return frame_count; }

// No-op here; DVI.wait_vsync is overridden in dvi_wasm.rb.
void dvi_wait_vsync(void) {}

// Render the current VRAM into the displayed framebuffer. Skipped in graphics
// mode so a Console redraw cannot clobber the graphics image.
void
dvi_text_commit(void)
{
  if (active_mode != DVI_MODE_TEXT) return;
  render_text();
  frame_count++;
}

// Graphics geometry: the logical resolution. At scale 2 the drawing is 320x240
// and gets pixel-doubled to the 640x480 display by dvi_graphics_commit.
int dvi_graphics_get_width(void) { return FB_WIDTH / graphics_scale; }
int dvi_graphics_get_height(void) { return FB_HEIGHT / graphics_scale; }
void dvi_set_graphics_scale(int scale) { if (scale == 1 || scale == 2) graphics_scale = scale; }

// Apply a text scale change immediately (no hardware VSync to defer to). The
// per-scale grid tables are filled by dvi_text_set_font; select the active grid
// and clamp the scroll offset into the (possibly smaller) row range, then
// repaint if text is on screen.
void
dvi_set_text_scale(int scale)
{
  if (scale != 1 && scale != 2) return;
  if (dvi_text_scale == scale) return;
  dvi_text_scale = scale;
  dvi_text_cols = dvi_text_cols_for_scale[scale];
  dvi_text_rows = dvi_text_rows_for_scale[scale];
  while (dvi_text_write_scroll_offset >= dvi_text_rows)
    dvi_text_write_scroll_offset -= dvi_text_rows;
  if (active_mode == DVI_MODE_TEXT) {
    render_text();
    frame_count++;
  }
}

// No browser back buffer: drawing already targets graphics_buf via
// dvi_get_framebuffer(). Kept so the platform contract links; never called here.
void dvi_graphics_set_back_buffer(uint8_t *bb) { (void)bb; }

// Present the graphics drawing buffer. At scale 1 a straight copy; at scale 2
// the 320x240 logical image is nearest-neighbor doubled to 640x480.
void
dvi_graphics_commit(void)
{
  if (graphics_scale == 1) {
    memcpy(framebuffer, graphics_buf, (size_t)FB_WIDTH * FB_HEIGHT);
  } else {
    int gw = FB_WIDTH / graphics_scale;   // 320
    int gh = FB_HEIGHT / graphics_scale;  // 240
    for (int y = 0; y < gh; y++) {
      const uint8_t *src = graphics_buf + y * gw;
      uint8_t *d0 = framebuffer + (2 * y) * FB_WIDTH;
      uint8_t *d1 = d0 + FB_WIDTH;
      for (int x = 0; x < gw; x++) {
        uint8_t px = src[x];
        d0[2 * x] = px; d0[2 * x + 1] = px;
        d1[2 * x] = px; d1[2 * x + 1] = px;
      }
    }
  }
  frame_count++;
}

// ---------------------------------------------------------------------------
// Browser entry points
// ---------------------------------------------------------------------------

// Initialize text mode: wire the shared core's buffers, load the fonts and
// clear the screen. Called once from harucom_init() before the OS boots.
EMSCRIPTEN_KEEPALIVE
void
dvi_wasm_init(void)
{
  dvi_text_write_vram = vram;
  dvi_text_write_row_has_wide = row_has_wide;
  dvi_text_glyph_bitmap = glyph_bitmap;
  memset(vram, 0, sizeof(vram));
  memset(row_has_wide, 0, sizeof(row_has_wide));
  memset(glyph_bitmap, 0, sizeof(glyph_bitmap));
  memset(framebuffer, 0, sizeof(framebuffer));
  memset(graphics_buf, 0, sizeof(graphics_buf));

  dvi_text_set_font(&font_mplus_f12r);
  dvi_text_set_bold_font(&font_mplus_f12b);
  dvi_text_set_wide_font(&font_mplus_j12_combined);
  dvi_text_init_palette();
  dvi_text_clear(0xF0); // white on black
  active_mode = DVI_MODE_TEXT;
  render_text();
}

// Pointer to the RGB332 framebuffer, for the JS canvas blit.
EMSCRIPTEN_KEEPALIVE
uint8_t *
harucom_dvi_framebuffer(void)
{
  return framebuffer;
}

EMSCRIPTEN_KEEPALIVE int harucom_dvi_width(void) { return FB_WIDTH; }
EMSCRIPTEN_KEEPALIVE int harucom_dvi_height(void) { return FB_HEIGHT; }

// Monotonic counter bumped on every commit, so the JS run loop can skip the
// canvas blit on frames where the framebuffer did not change.
EMSCRIPTEN_KEEPALIVE uint32_t harucom_dvi_frame_count(void) { return frame_count; }

#endif /* __EMSCRIPTEN__ */
