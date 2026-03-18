# DVI output via HSTX

The Harucom Board outputs DVI video using the RP2350's built-in
[HSTX][rp2350-hstx] (High-Speed Serial Transmit) peripheral.  HSTX
generates [TMDS][tmds]-encoded differential signals on GPIO 12-19,
directly driving a DVI connector without an external encoder IC.

[rp2350-hstx]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_hstx
[tmds]: https://en.wikipedia.org/wiki/Transition-minimized_differential_signaling

## Output format

### 640x480 timing

The output resolution is 640x480 @ 60 Hz (VGA DMT). The pixel clock is
25.0 MHz (-0.7% from 25.175 MHz standard), within typical display tolerance.

| Parameter | Pixels/Lines |
|---|---|
| H active | 640 |
| H front porch | 16 |
| H sync width | 96 |
| H back porch | 48 |
| **H total** | **800** |
| V active | 480 |
| V front porch | 10 |
| V sync width | 2 |
| V back porch | 33 |
| **V total** | **525** |

Sync polarity is negative for both HSYNC and VSYNC (0 = asserted).

### Display modes

Two display modes are supported, selected at initialization via
`dvi_start_mode()`:

**Pixel mode** (`DVI_MODE_PIXEL`): 320x240 RGB332 framebuffer (75 KB) in
main SRAM. HSTX performs 2x horizontal scaling via DMA_SIZE_8 byte-lane
replication (`ENC_N_SHIFTS=2`). Vertical 2x by line doubling in the DMA
IRQ handler.

**Text mode** (`DVI_MODE_TEXT`): text VRAM (106 columns x 37 rows) rendered
per-scanline at native 640x480 resolution. DMA uses DMA_SIZE_32 with
`ENC_N_SHIFTS=4` for 4 unique pixels per FIFO word. See [Text mode
rendering](#text-mode-rendering) below.

### RGB332 color encoding

Both modes use RGB332 pixel format (1 byte per pixel).

| Bits | Channel | Values |
|---|---|---|
| 7-5 | Red | 0-7 |
| 4-2 | Green | 0-7 |
| 1-0 | Blue | 0-3 |

HSTX TMDS lane mapping (configured in `expand_tmds`):

| Lane | Channel | NBITS | ROT |
|---|---|---|---|
| 0 | Blue | 1 | 26 |
| 1 | Green | 2 | 29 |
| 2 | Red | 2 | 0 |

### GPIO pinout

```
GP12 CK-   GP13 CK+   (TMDS clock, differential)
GP14 D0-   GP15 D0+   (Lane 0: blue + sync)
GP16 D1-   GP17 D1+   (Lane 1: green)
GP18 D2-   GP19 D2+   (Lane 2: red)
```

## System clock: 250 MHz

Text mode rendering requires sys_clk > clk_hstx. At a 1:1 ratio, DMA and
CPU compete for main SRAM bus bandwidth every cycle, inflating render time
beyond the scanline budget. A 2:1 ratio (250 MHz sys_clk, 125 MHz clk_hstx)
combined with render loop optimizations (font_byte_mask table in SCRATCH_Y,
uniform-attribute fast path) keeps the render within the blanking budget.
See [stability analysis](#stability-analysis) below.

### HSTX serialization

| Parameter | Value |
|---|---|
| clk_sys | 250 MHz |
| clk_hstx | 125 MHz (clk_sys / 2) |
| CLKDIV | 5 |
| N_SHIFTS | 5 |
| SHIFT | 2 bits |
| Pixel clock | 125 / 5 = 25.0 MHz |

### PLL configuration

```
VCO     = 12 MHz x 125 = 1500 MHz
sys_clk = 1500 / 6 / 1 = 250 MHz
VREG    = 1.15 V
```

### Peripheral clocks

Changing clk_sys does not affect clk_usb or clk_peri (both sourced from
PLL_USB at 48 MHz). UART baud rates remain correct.

## Core assignment

```
Core 0: mruby VM, stdio, timers (default alarm pool)
Core 1: DVI output (HSTX + DMA), BASEPRI-isolated
```

Core 1 sets `BASEPRI = 0x20` after DVI initialization to block all
interrupts except DMA_IRQ_1 (priority 0x00). This prevents flash-resident
IRQ handlers from executing on the DVI core.

### Interrupt layout

Core 0:

| IRQ | Source | Priority | Purpose |
|---|---|---|---|
| 3 | TIMER0_IRQ_3 | 0x80 | Default alarm pool (sleep_ms, mruby tasks) |
| 14 | USBCTRL_IRQ | 0x80 | USB device controller |
| 51 | User IRQ | 0x80 | USB CDC low-priority worker |

Core 1:

| IRQ | Source | Priority | Purpose |
|---|---|---|---|
| 11 | DMA_IRQ_1 | 0x00 | DMA scanline completion |

### Cross-core vsync signaling

`dvi_wait_vsync()` uses ARM SEV/WFE instead of WFI. WFI only wakes on
interrupts on the calling core's NVIC. SEV is a cross-core event signal
that wakes WFE on any core:

- DMA IRQ handler (core 1): issues `SEV` after incrementing `frame_count`
- `dvi_wait_vsync()` (any core): uses `WFE` to sleep until the event

## DMA architecture

Two-channel CMD-to-DATA DMA with double-buffered descriptor buffers.

- **Channel 0 (CMD)**: reads 4-word descriptors, writes to channel 1's
  Alias 3 registers via RING_WRITE (size = 4, 2^4 = 16 bytes)
- **Channel 1 (DATA)**: executes transfers to HSTX FIFO, chains back to
  CMD after each descriptor
- **NULL stop**: zero-length descriptor triggers DMA_IRQ_1

Active scanlines are batched 4-at-a-time (N=4, 120 batches per frame).
Blanking lines remain single (45 IRQs per frame).  See
[doc/dvi/batch-rendering.md](dvi/batch-rendering.md) for descriptor
layout, line buffer design, and measured performance.

## Text mode rendering

### Text VRAM

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

### Font: 12px M+

- Half-width: 6px wide, 13px tall. Cached in a 512-stride SRAM row cache
  (6656 bytes). Regular glyphs at index 0-255, bold at 256-511. Zero flash
  access during rendering.
- Full-width: 12px wide, 13px tall. Source data is interleaved regular+bold
  in flash XIP (52-byte stride per glyph pair). Rendered from an SRAM wide
  glyph cache to avoid QMI bus contention (see below).

### Wide glyph cache

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

### Scanline renderer

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

## Memory layout

| Region | Size | Contents |
|---|---|---|
| Flash (XIP) | ~920 KB | Firmware, font data (~400 KB), mruby library |
| Main SRAM | ~192 KB | text_vram (15.7 KB), narrow_row_cache (6.6 KB), wide_row_cache (26 KB), line_buf (5.2 KB), framebuf (75 KB), stacks, BSS |
| SCRATCH_X | ~3.6 KB | IRQ handler + render code |
| SCRATCH_Y | 4 KB | font_byte_mask (2 KB) + pico-sdk default stack (2 KB, unused after BSS stack switch) |
| PSRAM (QMI CS1) | 8 MB | mruby heap |

### Main SRAM bank-offset technique

Main SRAM has 8 banks striped at 4-byte boundaries. Two buffers at offset N
share the same bank when N % 32 = 0.

Each line buffer is padded to 644 bytes (640 + 4). The word offset between
consecutive buffers is 161, so buf[i] maps to SRAM bank (161*i % 8).  With
8 buffers (2N for batch rendering), all buffers land on different banks
{0,1,2,3,4,5,6,7}, giving zero bank collisions between any pair of
simultaneously-active buffers.

## Stability analysis

### QMI bus contention

The QMI bus is shared between flash (CS0) and PSRAM (CS1). The 16 KB XIP
cache covers both chip selects. When the mruby VM alternates between flash
code and PSRAM data, the XIP cache thrashes, generating heavy QMI traffic.

The wide glyph cache keeps all render-time font reads in SRAM, so the
render path has no flash access. Text mode is stable regardless of mruby
VM activity.

### Main SRAM bus contention

At sys_clk = clk_hstx (1:1 ratio), DMA and CPU compete for main SRAM bus
bandwidth on every cycle. The 2:1 ratio (250 MHz sys_clk, 125 MHz clk_hstx)
reduces contention enough for the render to fit within the scanline budget.

Measured per-line render cycles at 250 MHz:

| Workload | Cycles |
|----------|--------|
| Narrow-only (uniform attr) | ~1,837 |
| Mixed-attr spike | ~2,321 |

The following techniques keep the per-line render time low:

1. **font_byte_mask table in SCRATCH_Y**: maps font byte (0-255) to
   pre-computed (mask_hi, mask_lo) pairs. A single ldrd from SRAM9
   (separate bus port) avoids Main SRAM contention with DMA.
   256 entries x 8 bytes = 2 KB.

2. **Uniform-attribute fast path**: tracks per-row attribute uniformity via
   `row_uniform_attr[]`. When all cells share the same attr, pre-computes
   bg4/xor4 once and skips all per-cell ubfx+cmp+bne attr checks.

3. **DMA trigger reordering**: the IRQ handler triggers the next
   pre-prepared descriptor buffer immediately after acknowledgment, before
   diagnostics.

4. **SRAM wide glyph cache**: all full-width font reads come from SRAM,
   avoiding flash XIP access entirely
   (see [Wide glyph cache](#wide-glyph-cache)).

5. **Set-time pre-computation**: bold slot offset stored in `cell.ch` at
   write time, eliminating tst/it/addne (3 instructions per wide cell) from
   the render loop.

6. **Load-latency interleaving**: next nibble address computed during the
   2-cycle ldr bubble in the wide sub-path.

### Diagnostic instrumentation

The driver includes counters readable via `dvi_output.h` (gated by
`DVI_DIAGNOSTICS`):

- `dvi_irq_max_cycles`: DWT cycle count for prepare_batch_dma
- `dvi_render_max/min/last_cycles`: per-line render timing
- `dvi_batch_render_max/last_cycles`: total batch render time (sum of
  BATCH_SIZE line renders)
- `dvi_irq_interval_min/max`: IRQ-to-IRQ interval in cycles
- `dvi_fifo_empty_count`: HSTX FIFO empty events at IRQ entry
- `dvi_fifo_empty_log[]`: scanline numbers of the last 8 empty events
- `dvi_fifo_min_level`: minimum FIFO level per diagnostic interval
- `dvi_read_bus_counters()`: SRAM9 contested/total access counts

## Initialization order

```c
dvi_init_clock();           // 250 MHz, VREG 1.15V
stdio_init_all();           // UART/USB CDC on core 0
psram_init();               // PSRAM timing at 375 MHz
dvi_text_set_font(...);     // configure fonts before DVI starts
setup_text_demo();          // (optional) fill text VRAM

multicore_launch_core1_with_stack(core1_dvi_entry, ...);
// core1_dvi_entry: dvi_start_mode(DVI_MODE_TEXT), BASEPRI, WFI loop

run_mruby();                // mruby VM on core 0
```

Font setup must happen before `dvi_start_mode()` because the scanline
renderer needs the font pointer and SRAM cache. Text VRAM content should be
written after core 1 starts (dvi_start_mode clears VRAM).

## References

- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
  (HSTX: section 4.8, QMI: section 4.4, DMA: section 2.5, Bus fabric: section 2.1)
- [pico-sdk documentation](https://www.raspberrypi.com/documentation/pico-sdk/)
- [Arm Cortex-M33 Technical Reference Manual](https://developer.arm.com/documentation/100230/latest/)
- [PicoLibSDK `disphstx`](https://github.com/Panda381/PicoLibSDK):
  CMD-to-DATA DMA architecture reference
- [pico-examples `hstx/dvi_out_hstx_encoder`](https://github.com/raspberrypi/pico-examples/tree/master/hstx/dvi_out_hstx_encoder):
  HSTX DVI reference example
