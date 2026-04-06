# Text Mode Rendering

Text mode renders a 106x37 character grid at native 640x480 resolution.
Each scanline is rendered by the DMA IRQ handler on Core 1, converting
text VRAM cells into 640 RGB332 pixels via inline ARM Thumb-2 assembly.

## Text VRAM

106 columns x 37 rows of 4-byte cells, double-buffered:

```c
typedef struct {
    uint16_t ch;   // character code (ASCII or linear JIS index)
    uint8_t attr;  // bits 7-4: fg palette index, bits 3-0: bg palette index
    uint8_t flags; // DVI_CELL_FLAG_WIDE_L, _WIDE_R, _BOLD
} dvi_text_cell_t;
```

For narrow characters, `ch` holds the ASCII code (0-255), with bit 8 set
for bold (mapping into the 256-511 bold region of the narrow cache).
For wide characters, `ch` holds the linear JIS index directly (used by
`write_line` for glyph re-rendering from scrollback).

16-color palette maps 4-bit indices to RGB332 values (VGA-compatible
defaults).

## Ring Buffer Scroll

VRAM rows are accessed via a ring buffer offset rather than memmove.
`scroll_offset` maps logical row N to physical row
`(N + scroll_offset) % text_rows`. Scroll up/down adjusts the offset and
clears only the vacated row, making scroll O(1) regardless of screen size.

The scroll offset is double-buffered alongside the VRAM pointers: Core 0
writes `write_scroll_offset`, and Core 1 reads `render_scroll_offset`
(swapped at VBlank).

## Font: 12px M+

- Half-width: 6px wide, 13px tall. Cached in a 512-stride SRAM row cache
  (6656 bytes). Regular glyphs at index 0-255, bold at 256-511. Zero flash
  access during rendering.
- Full-width: 12px wide, 13px tall. Source data is interleaved regular+bold
  in flash XIP (52-byte stride per glyph pair). Rendered into a per-position
  glyph bitmap at character-write time (see below).

## Per-Position Glyph Bitmap

Full-width font bitmaps cannot be read from flash XIP during rendering
because the QMI bus is shared with PSRAM. Instead of a slot-based cache,
each screen position stores its own glyph bitmap data.

The glyph bitmap is overlaid on the graphics framebuffer via a union
(`screenbuf`), since the framebuffer is unused in text mode.

Layout: `screenbuf.glyph_bitmap[(phys_row * 13 + glyph_y) * 106 + col]`

- Narrow cells: the bitmap position is unused (narrow glyphs are read from
  the narrow row cache instead)
- Wide-left cell: low 8 bits of the 12-bit glyph row
- Wide-right cell: high 8 bits (4 bits meaningful)
- `ldrh` at the wide-left position reads the full 16-bit glyph row
  (little-endian)

Size: 37 rows x 13 scanlines x 106 columns = 50,986 bytes.

The bitmap is single-buffered (shared between both VRAM buffers). This is
safe because glyph bitmap bytes do not affect the renderer's control flow.
The worst case is a partial glyph update (some scanlines showing the old
glyph, some the new) visible for 1 frame.

Populated by `render_wide_glyph_at()`, called from `dvi_text_put_wide_char()`
and `dvi_text_write_line()` on Core 0.

## Scanline Renderer

The renderer converts one row of text VRAM into 640 RGB332 bytes using
inline ARM Thumb-2 assembly. Branchless pixel selection via font-byte-mask
LUT:

```
pixel = bg4 ^ (xor4 & font_byte_mask[byte][0..1])
```

`font_byte_mask[256][2]` (2 KB) resides in SCRATCH_Y (SRAM9, separate bus
port from Main SRAM) to eliminate DMA bus contention during rendering.

Two render paths selected by `row_has_wide[]`:

| Path | Dispatch condition | Per-cell cost |
|---|---|---|
| Narrow-only | no wide chars in row | ~21 cycles (2-cell pair via ldrd) |
| Mixed | row has wide chars | ~23 narrow / ~28 wide (single-cell dispatch) |

Both paths perform per-cell attr checks. The narrow-only path processes
2 cells per iteration via `ldrd` pair loading.

In the mixed path, `glyph_ptr` advances sequentially through the
per-position glyph bitmap (+1 for narrow, +2 for wide), staying
synchronized with the cell position. Wide glyphs are loaded with
`ldrh [glyph_ptr]` instead of the previous slot-indexed cache access.

Key render-loop optimizations:

- **Load-latency interleaving**: next nibble address computed during the
  2-cycle ldr bubble to hide pipeline stalls in the wide sub-path.
- **Set-time pre-computation**: bold narrow offset is stored in `cell.ch`
  at character-write time (bit 8 set), not computed at render time on
  Core 1.

The render function and IRQ handler are placed in SCRATCH_X to avoid
flash instruction fetch during rendering.
