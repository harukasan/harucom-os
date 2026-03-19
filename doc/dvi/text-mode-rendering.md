# Text Mode Rendering

Text mode renders a 106x37 character grid at native 640x480 resolution.
Each scanline is rendered by the DMA IRQ handler on Core 1, converting
text VRAM cells into 640 RGB332 pixels via inline ARM Thumb-2 assembly.

## Text VRAM

106 columns x 37 rows of 4-byte cells:

```c
typedef struct {
    uint16_t ch;   // character code (ASCII or linear JIS index)
    uint8_t attr;  // bits 7-4: fg palette index, bits 3-0: bg palette index
    uint8_t flags; // DVI_CELL_FLAG_WIDE_L, _WIDE_R, _BOLD
} dvi_text_cell_t;
```

16-color palette maps 4-bit indices to RGB332 values (VGA-compatible
defaults).

## Font: 12px M+

- Half-width: 6px wide, 13px tall. Cached in a 512-stride SRAM row cache
  (6656 bytes). Regular glyphs at index 0-255, bold at 256-511. Zero flash
  access during rendering.
- Full-width: 12px wide, 13px tall. Source data is interleaved regular+bold
  in flash XIP (52-byte stride per glyph pair). Rendered from an SRAM wide
  glyph cache to avoid QMI bus contention (see below).

## Wide Glyph Cache

Full-width font bitmaps cannot be read from flash XIP during rendering
because the QMI bus is shared with PSRAM. The wide glyph cache copies
needed glyph rows into SRAM on Core 0 at character-write time, so Core 1
never touches flash.

- 512 cache slots, row-major layout: `wide_row_cache[glyph_y * stride + slot]`
- Regular glyphs at slots 0-511, bold at 512-1023 (26 KB total)
- 1024-entry hash table maps linear JIS index to cache slot (open addressing,
  linear probing)
- Populated by `dvi_text_put_wide_char()` on Core 0
- On overflow, the cache scans VRAM and re-maps slots in-place

Bold characters store `slot + WIDE_CACHE_SLOTS` in `cell.ch` at write time
so the render loop indexes directly into the bold region without a runtime
branch.

## Scanline Renderer

The renderer converts one row of text VRAM into 640 RGB332 bytes using
inline ARM Thumb-2 assembly. Branchless pixel selection via font-byte-mask
LUT:

```
pixel = bg4 ^ (xor4 & font_byte_mask[byte][0..1])
```

`font_byte_mask[256][2]` (2 KB) resides in SCRATCH_Y (SRAM9, separate bus
port from Main SRAM) to eliminate DMA bus contention during rendering.

Four render paths selected by `row_has_wide[]` and `row_uniform_attr[]`:

| Path | Dispatch condition | Per-cell cost | Typical cycles |
|---|---|---|---|
| Uniform-attr narrow-only | no wide, uniform attr | ~12 cycles (2-cell pair) | ~1,763 |
| Mixed-attr narrow-only | no wide, mixed attrs | ~21 cycles (2-cell pair) | ~2,050 |
| Uniform-attr mixed | has wide, uniform attr | ~20 narrow / ~25 wide | ~2,080 |
| Non-uniform-attr mixed | has wide, mixed attrs | ~23 narrow / ~28 wide | ~2,200 |

Cycle counts are per-line render time.

Key render-loop optimizations:

- **Load-latency interleaving**: next nibble address computed during the
  2-cycle ldr bubble to hide pipeline stalls in the wide sub-path.
- **Set-time pre-computation**: bold slot offset and per-row uniform-attr
  flags are computed on Core 0 at character-write time, not at render time
  on Core 1.

The render function and IRQ handler are placed in SCRATCH_X to avoid
flash instruction fetch during rendering.
