// Shared text-mode core for DVI (platform independent).
//
// The text VRAM cell semantics, the cell writers (dvi_text_put_*, scroll,
// clear, read/write_line, ...), the narrow font cache and the 16-color palette
// are identical on every platform, so they live in src/dvi_text.c and are used
// by both the RP2350 HSTX/DMA renderer (ports/rp2350/dvi_output.c) and the
// browser canvas renderer (ports/posix).
//
// The platform owns the things that are hardware/layout specific: the VRAM
// buffer(s) and the double-buffer swap (dvi_text_commit), the wide-glyph bitmap
// storage (on RP2350 it is unioned with the graphics framebuffer to save SRAM),
// and the scanline -> pixel renderer. The platform points the shared pointers
// below at its buffers during init.

#ifndef DVI_TEXT_INTERNAL_H
#define DVI_TEXT_INTERNAL_H

#include "dvi.h"

#ifdef __cplusplus
extern "C" {
#endif

// 12px renderer geometry (6px half-width, 13px glyph height, 106 columns).
#define TEXT_GLYPH_WIDTH_12WIDE  6
#define TEXT_GLYPH_HEIGHT_12WIDE 13
#define NARROW_CACHE_STRIDE      512
#define GLYPH_BITMAP_STRIDE      DVI_TEXT_MAX_COLS
#define GLYPH_BITMAP_SIZE \
  (DVI_TEXT_MAX_ROWS * TEXT_GLYPH_HEIGHT_12WIDE * GLYPH_BITMAP_STRIDE)

// Shared text state (defined in src/dvi_text.c).
extern int dvi_text_cols;
extern int dvi_text_rows;
extern uint32_t dvi_text_palette32[16]; // RGB332 byte replicated to 4 lanes
// Row-major narrow font cache: [glyph_y * 512 + ch], regular 0-255, bold 256-511.
extern uint8_t dvi_text_narrow_cache[TEXT_GLYPH_HEIGHT_12WIDE * NARROW_CACHE_STRIDE];

// The cell buffer the writers write to, and the per-row wide-char flags. The
// platform allocates these and points the pointers here (RP2350 swaps them
// between two buffers at VBlank; the browser uses a single buffer).
extern dvi_text_cell_t *dvi_text_write_vram;
extern uint8_t *dvi_text_write_row_has_wide;
// Ring-buffer scroll offset: logical row N maps to physical (N + offset) % rows.
extern int dvi_text_write_scroll_offset;

// Wide-glyph bitmap storage, provided by the platform (RP2350 unions it with the
// graphics framebuffer). dvi_text_render_wide_glyph() writes here; the renderer
// reads it. Layout: [(phys_row * 13 + glyph_y) * GLYPH_BITMAP_STRIDE + col].
extern uint8_t *dvi_text_glyph_bitmap;

// Reset the palette to the built-in default (called by the platform at init).
void dvi_text_init_palette(void);

// Map a logical text row to its physical row in the ring buffer.
int dvi_text_physical_row(int logical_row, int offset);

// Rasterize a full-width glyph into dvi_text_glyph_bitmap at (col, phys_row).
void dvi_text_render_wide_glyph(int col, int phys_row, uint16_t linear_jis,
                                const dvi_font_t *font, bool bold);

#ifdef __cplusplus
}
#endif

#endif /* DVI_TEXT_INTERNAL_H */
