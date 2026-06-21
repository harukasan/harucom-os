// Browser (emscripten) DVI port: renders the shared text VRAM into an RGB332
// framebuffer that JavaScript blits to a canvas. Reuses the platform-independent
// text core (src/dvi_text.c) for the cell writers / font cache / palette; this
// file owns the single VRAM buffer, the wide-glyph bitmap storage, the
// framebuffer and the cell-to-pixel renderer (the wasm counterpart of the
// RP2350 HSTX/DMA scanline renderer).

#ifdef __EMSCRIPTEN__

#include <string.h>
#include <emscripten.h>

#include "dvi.h"
#include "dvi_text_internal.h"

// Text-mode fonts (generated headers; same set the board uses in src/main.c).
#include "font_mplus_f12r.h"
#include "font_mplus_f12b.h"
#include "font_mplus_j12_combined.h"

// Framebuffer geometry comes from the shared DVI headers (dvi.h surface size,
// dvi_text_internal.h cell width) so the wasm renderer cannot drift from the
// board renderer or the shared text core.
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
static uint8_t *back_framebuf = NULL;

// ---------------------------------------------------------------------------
// Text renderer: VRAM cells -> RGB332 framebuffer (faithful to the RP2350
// 12px mixed-width scanline renderer, in portable C).
// ---------------------------------------------------------------------------

static void
render_text(void)
{
  uint8_t border_bg = (uint8_t)dvi_text_palette32[0]; // palette[0] (background)

  for (int scan = 0; scan < FB_HEIGHT; scan++) {
    uint8_t *out = framebuffer + scan * FB_WIDTH;
    int text_row = scan / TEXT_GLYPH_HEIGHT_12WIDE;
    int glyph_y = scan % TEXT_GLYPH_HEIGHT_12WIDE;

    if (text_row >= dvi_text_rows) {
      memset(out, border_bg, FB_WIDTH);
      continue;
    }

    int phys_row = dvi_text_physical_row(text_row, dvi_text_write_scroll_offset);

    const dvi_text_cell_t *row = &dvi_text_write_vram[phys_row * dvi_text_cols];
    const uint8_t *nrow = dvi_text_narrow_cache + glyph_y * NARROW_CACHE_STRIDE;
    const uint8_t *grow = dvi_text_glyph_bitmap +
                          (phys_row * TEXT_GLYPH_HEIGHT_12WIDE + glyph_y) * GLYPH_BITMAP_STRIDE;
    int x = 0;

    for (int col = 0; col < dvi_text_cols; col++) {
      dvi_text_cell_t cell = row[col];
      uint8_t fg = (uint8_t)dvi_text_palette32[(cell.attr >> 4) & 0x0F];
      uint8_t bg = (uint8_t)dvi_text_palette32[cell.attr & 0x0F];

      if (cell.flags & DVI_CELL_FLAG_WIDE_L) {
        // Full-width: 12px from the glyph bitmap (low byte = cols 0-7, high
        // byte = cols 8-11), 1bpp MSB-first.
        uint8_t b0 = grow[col];
        uint8_t b1 = grow[col + 1];
        for (int px = 0; px < 8; px++) out[x++] = (b0 & (0x80 >> px)) ? fg : bg;
        for (int px = 0; px < 4; px++) out[x++] = (b1 & (0x80 >> px)) ? fg : bg;
        col++; // consume the WIDE_R cell
      } else if (cell.flags & DVI_CELL_FLAG_WIDE_R) {
        // Stray right half (e.g. mid-glyph scroll); paint background.
        for (int px = 0; px < TEXT_GLYPH_WIDTH_12WIDE; px++) out[x++] = bg;
      } else {
        // Half-width: 6px from the narrow cache (bold is encoded as ch|0x100,
        // which indexes the 256-511 region of the row cache).
        uint8_t fb = nrow[cell.ch & 0x1FF];
        for (int px = 0; px < TEXT_GLYPH_WIDTH_12WIDE; px++)
          out[x++] = (fb & (0x80 >> px)) ? fg : bg;
      }
    }
    // Right margin (640 - cols*6) stays background.
    while (x < FB_WIDTH) out[x++] = border_bg;
  }
}

// ---------------------------------------------------------------------------
// Platform contract (the parts the RP2350 port keeps in dvi_output.c)
// ---------------------------------------------------------------------------

void dvi_set_mode(dvi_mode_t mode) { active_mode = mode; }
void dvi_set_blanking(bool enable) { (void)enable; }
uint8_t *dvi_get_framebuffer(void) { return framebuffer; }
uint32_t dvi_get_frame_count(void) { return frame_count; }

// No-op: there is no hardware vsync in the browser, and spinning here would
// freeze the single browser thread. Yielding is done at the Ruby level instead,
// where harucom-os-wasm/mrblib/dvi_wasm.rb overrides DVI.wait_vsync to sleep_ms
// so the task suspends and hands control back to the browser run loop.
void dvi_wait_vsync(void) {}

// Text commit: render the current VRAM into the framebuffer. Single buffered,
// so there is no buffer swap; JS reads the framebuffer on its own rAF loop.
void
dvi_text_commit(void)
{
  render_text();
  frame_count++;
}

// Graphics mode (text-only for now; provide the contract so the binding links).
int dvi_graphics_get_width(void) { return FB_WIDTH / graphics_scale; }
int dvi_graphics_get_height(void) { return FB_HEIGHT / graphics_scale; }
void dvi_set_graphics_scale(int scale) { if (scale == 1 || scale == 2) graphics_scale = scale; }
void dvi_graphics_set_back_buffer(uint8_t *bb) { back_framebuf = bb; }
void dvi_graphics_commit(void)
{
  if (back_framebuf) {
    int gw = dvi_graphics_get_width(), gh = dvi_graphics_get_height();
    memcpy(framebuffer, back_framebuf, (size_t)gw * gh);
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
