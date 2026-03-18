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
combined with render loop optimizations (expanded nibble table in SCRATCH_Y,
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

Per-scanline CMD-to-DATA DMA with double-buffered descriptor buffers.

- **Channel 0 (CMD)**: reads 4-word descriptors, writes to channel 1's
  Alias 3 registers via RING_WRITE
- **Channel 1 (DATA)**: executes transfers to HSTX FIFO, chains back to
  CMD after each descriptor
- **NULL stop**: zero-length descriptor triggers DMA_IRQ_1

Each scanline uses 3 descriptor groups (12 words):

```
Group 0 (sync):  DMA_SIZE_32, DREQ_HSTX -> hsync_cmd (7 words)
Group 1 (pixel): DMA_SIZE_8 or DMA_SIZE_32, DREQ_HSTX -> pixel/line data
Group 2 (stop):  DREQ_FORCE, NULL address -> triggers IRQ
```

The IRQ handler triggers the next pre-prepared buffer, then builds
descriptors for two scanlines ahead.

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
  access during narrow-only rendering.
- Full-width: 12px wide, 13px tall. Interleaved regular+bold in flash XIP.
  52-byte stride per glyph pair. Unusable with mruby active due to QMI bus
  contention (see below).

### Scanline renderer

The renderer converts one row of text VRAM into 640 RGB332 bytes using
inline ARM Thumb-2 assembly. Branchless pixel selection via nibble-mask LUT:

```
pixel = bg4 ^ (xor4 & nibble_mask[nibble])
```

Three render paths selected by `row_has_wide[]` and `row_uniform_attr[]`:

- Uniform-attr narrow-only: pre-computed bg/xor, expanded nibble table in
  SCRATCH_Y, no per-cell attr checks. ~1,763 cycles including IRQ overhead.
- Mixed-attr narrow-only: expanded nibble table with per-cell attr checks.
  ~2,050 cycles including IRQ overhead.
- Mixed (narrow + wide): single-cell dispatch with narrow/wide sub-paths.

The render function and IRQ handler are placed in SCRATCH_X to avoid
flash instruction fetch during rendering.

## Memory layout

| Region | Size | Contents |
|---|---|---|
| Flash (XIP) | ~920 KB | Firmware, font data (~400 KB), mruby library |
| Main SRAM | ~156 KB | text_vram (15.7 KB), narrow_row_cache (6.6 KB), line_buf (1.3 KB), framebuf (75 KB), stacks, BSS |
| SCRATCH_X | ~3.4 KB | IRQ handler + render code |
| SCRATCH_Y | 4 KB | expanded_nibble (2 KB) + pico-sdk default stack (2 KB, unused after BSS stack switch) |
| PSRAM (QMI CS1) | 8 MB | mruby heap |

### Main SRAM bank-offset technique

Main SRAM has 8 banks striped at 4-byte boundaries. Two buffers at offset N
share the same bank when N % 32 = 0.

`line_buf[2][640]` has a natural offset of 640 bytes (640 % 32 = 0), so both
buffers always hit the same bank, causing 100% DMA/CPU bank collision.
Padding each buffer to 644 bytes shifts buf[1] by 1 bank position
(644 / 4 % 8 = 1), reducing same-bank collisions from 100% to 1/8.

## Stability analysis

### QMI bus contention

The QMI bus is shared between flash (CS0) and PSRAM (CS1). The 16 KB XIP
cache covers both chip selects. When the mruby VM alternates between flash
code and PSRAM data, the XIP cache thrashes, generating heavy QMI traffic.

Impact on text mode:
- Half-width rendering reads from SRAM cache only (no QMI access). Stable.
- Full-width rendering reads font bitmaps from flash XIP. QMI contention
  with mruby's PSRAM access causes render stalls of 20,000+ cycles
  (budget: 12,000 cycles). Unusable with mruby active.

### Main SRAM bus contention

At sys_clk = clk_hstx (1:1 ratio), DMA and CPU compete for main SRAM bus
bandwidth on every cycle. Measured effects:

| sys_clk | ratio | render_last | fifo_empty | fifo_min | result |
|---------|-------|-------------|------------|----------|--------|
| 125 MHz | 1:1 | 4,555 | >500/sec | -- | unstable |
| 250 MHz | 2:1 | 2,137 | ~1/10 sec | -- | nearly stable (pre-optimization) |
| 375 MHz | 3:1 | 2,137 | 0 | -- | fully stable |
| 250 MHz | 2:1 | 1,763 | 0 | 7 | **fully stable (optimized)** |

The initial 250 MHz attempt (2:1 ratio) suffered rare FIFO underflows due
to multi-master main SRAM bank contention between Core 0 (mruby), Core 1
(render), and DMA. The render (~2,137 cycles) exceeded the blanking budget
(1,600 cycles), spilling into the active pixel period where DMA reads
caused additional bus stalls.

Three optimizations brought the render within the blanking budget at 250 MHz:

1. **Pre-expanded nibble table in SCRATCH_Y**: maps font byte (0-255) to
   pre-computed (mask_hi, mask_lo) pairs. Replaces two nibble_mask lookups
   (Main SRAM) with a single ldrd from SRAM9 (separate bus port, zero DMA
   contention). 256 entries x 8 bytes = 2 KB.

2. **Uniform-attribute fast path**: tracks per-row attribute uniformity via
   `row_uniform_attr[]`. When all cells share the same attr, pre-computes
   bg4/xor4 once and skips all per-cell ubfx+cmp+bne attr checks.

3. **DMA trigger reordering**: moves the DMA descriptor trigger to
   immediately after IRQ acknowledgment, before FIFO diagnostics. Recovers
   ~20 cycles of blanking margin.

Combined savings: ~2,137 to ~1,484 cycles (pure render), ~1,763 cycles
including IRQ overhead. The 8-entry HSTX FIFO (fifo_min=7) absorbs any
residual Core 0 vs DMA contention during the active pixel period.

### Diagnostic instrumentation

The driver includes counters readable via `dvi_output.h`:

- `dvi_irq_max_cycles` / `dvi_irq_last_cycles`: DWT cycle count for the
  IRQ handler
- `dvi_render_max_cycles` / `dvi_render_last_cycles`: cycle count for the
  scanline render
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
