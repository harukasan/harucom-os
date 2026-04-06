# DVI output via HSTX

The Harucom Board outputs DVI video using the RP2350's built-in
[HSTX][rp2350-hstx] (High-Speed Serial Transmit) peripheral.  HSTX
generates [TMDS][tmds]-encoded differential signals on GPIO 12-19,
directly driving a DVI connector without an external encoder IC.

[rp2350-hstx]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_hstx
[tmds]: https://en.wikipedia.org/wiki/Transition-minimized_differential_signaling

## Ruby API

### DVI

Class: `DVI` (provided by picoruby-dvi mrbgem)

- [DVI.set_mode](#dviset_modemode)
- [DVI.frame_count](#dviframe_count---integer)
- [DVI.wait_vsync](#dviwait_vsync)

`DVI` provides display output control. Two display modes are available:
`DVI::TEXT_MODE` (106x37 text grid at 640x480) and `DVI::GRAPHICS_MODE`
(640x480 RGB332 framebuffer).

```ruby
DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0x0F)
loop do
  DVI::Text.put_string(0, 0, "Hello!", 0xF0)
  DVI::Text.commit
end
```

#### DVI.set_mode(mode)

Switch display mode. `mode` is `DVI::TEXT_MODE` or `DVI::GRAPHICS_MODE`.
The switch is applied at the next VBlank.

#### DVI.frame_count -> Integer

Return the number of frames rendered since DVI output started. Increments
once per VBlank (approximately 60 per second).

#### DVI.wait_vsync

Block until the next VBlank. See
[Cross-core vsync signaling](#cross-core-vsync-signaling) for details.

### DVI::Text

Class: `DVI::Text` (provided by picoruby-dvi mrbgem)

- [DVI::Text.put_char](#dvitextput_charcol-row-ch-attr)
- [DVI::Text.put_string](#dvitextput_stringcol-row-str-attr)
- [DVI::Text.clear](#dvitextclearattr)
- [DVI::Text.clear_line](#dvitextclear_linerow-attr)
- [DVI::Text.clear_range](#dvitextclear_rangecol-row-width-attr)
- [DVI::Text.scroll_up](#dvitextscroll_uplines-attr)
- [DVI::Text.scroll_down](#dvitextscroll_downlines-attr)
- [DVI::Text.get_attr](#dvitextget_attrcol-row---integer)
- [DVI::Text.set_attr](#dvitextset_attrcol-row-attr)
- [DVI::Text.commit](#dvitextcommit)

`DVI::Text` provides text mode rendering with double-buffered VRAM.
Characters are placed on a 106-column, 37-row grid. The `attr` byte
encodes foreground (bits 7-4) and background (bits 3-0) palette indices.

All write operations modify the back buffer. Call `commit` to swap the
back buffer to the front buffer at VBlank, preventing tearing.

Constants: `DVI::Text::COLS` (106), `DVI::Text::ROWS` (37).

#### DVI::Text.put_char(col, row, ch, attr)

Place a single character at the given grid position.

#### DVI::Text.put_string(col, row, str, attr)

Write a UTF-8 string starting at the given position. Half-width and
full-width (CJK) characters are supported.

#### DVI::Text.clear(attr)

Clear the entire text VRAM, filling all cells with spaces and the given
attribute.

#### DVI::Text.clear_line(row, attr)

Clear a single row, filling all cells with spaces and the given attribute.

#### DVI::Text.clear_range(col, row, width, attr)

Clear a partial range within a single row. Cells from `col` to
`col + width - 1` are filled with spaces and the given attribute.

#### DVI::Text.scroll_up(lines, attr)

Scroll VRAM contents up by the specified number of lines. Bottom lines
are cleared with the given attribute.

#### DVI::Text.scroll_down(lines, attr)

Scroll VRAM contents down by the specified number of lines. Top lines
are cleared with the given attribute.

#### DVI::Text.get_attr(col, row) -> Integer

Read the attribute byte of the cell at the given position.

#### DVI::Text.set_attr(col, row, attr)

Write the attribute byte of the cell at the given position. Useful for
cursor rendering via foreground/background inversion:

```ruby
attr = DVI::Text.get_attr(col, row)
DVI::Text.set_attr(col, row, (attr & 0x0F) << 4 | (attr >> 4))
```

#### DVI::Text.commit

Swap the back buffer to the front buffer at the next VBlank. Blocks
until the swap completes, then copies the front buffer state to the new
back buffer. All write operations between `commit` calls are
accumulated in the back buffer and become visible atomically.

### DVI::Graphics

Class: `DVI::Graphics` (provided by picoruby-dvi mrbgem)

- [DVI::Graphics.width](#dvigraphicswidth---integer)
- [DVI::Graphics.height](#dvigraphicsheight---integer)
- [DVI::Graphics.set_resolution](#dvigraphicsset_resolutionwidth-height)
- [DVI::Graphics.commit](#dvigraphicscommit)
- [DVI::Graphics.set_pixel](#dvigraphicsset_pixelx-y-color)
- [DVI::Graphics.get_pixel](#dvigraphicsget_pixelx-y---integer)
- [DVI::Graphics.fill](#dvigraphicsfillcolor)
- [DVI::Graphics.fill_rect](#dvigraphicsfill_rectx-y-width-height-color)
- [DVI::Graphics.draw_rect](#dvigraphicsdraw_rectx-y-width-height-color)
- [DVI::Graphics.fill_circle](#dvigraphicsfill_circlecx-cy-r-color)
- [DVI::Graphics.draw_circle](#dvigraphicsdraw_circlecx-cy-r-color)
- [DVI::Graphics.fill_ellipse](#dvigraphicsfill_ellipsecx-cy-rx-ry-color)
- [DVI::Graphics.draw_ellipse](#dvigraphicsdraw_ellipsecx-cy-rx-ry-color)
- [DVI::Graphics.fill_triangle](#dvigraphicsfill_trianglex0-y0-x1-y1-x2-y2-color)
- [DVI::Graphics.fill_arc](#dvigraphicsfill_arccx-cy-r-start-stop-color)
- [DVI::Graphics.draw_arc](#dvigraphicsdraw_arccx-cy-r-start-stop-color)
- [DVI::Graphics.draw_line](#dvigraphicsdraw_linex0-y0-x1-y1-color)
- [DVI::Graphics.draw_thick_line](#dvigraphicsdraw_thick_linex0-y0-x1-y1-thickness-color)
- [DVI::Graphics.draw_text](#dvigraphicsdraw_textx-y-text-color-font-wide_font)
- [DVI::Graphics.text_width](#dvigraphicstext_widthtext-font-wide_font---integer)
- [DVI::Graphics.font_height](#dvigraphicsfont_heightfont---integer)
- [DVI::Graphics.draw_image](#dvigraphicsdraw_imagedata-x-y-w-h)
- [DVI::Graphics.draw_image_masked](#dvigraphicsdraw_image_maskeddata-mask-x-y-w-h)
- [DVI::Graphics.set_blend_mode](#dvigraphicsset_blend_modemode)
- [DVI::Graphics.set_alpha](#dvigraphicsset_alphavalue)

`DVI::Graphics` provides pixel-level framebuffer access with drawing
primitives. Resolution is switchable at runtime between 640x480 (native)
and 320x240 (2x scaled to 640x480 on output). RGB332 format (1 byte per
pixel).

Double buffering is enabled automatically: at 640x480 the back buffer is
in PSRAM, at 320x240 it uses spare SRAM (fast). `commit` copies the back
buffer to the front buffer at VBlank.

For a higher-level stateful API, see the [P5 drawing library](p5.md).

```ruby
DVI.set_mode(DVI::GRAPHICS_MODE)
DVI::Graphics.fill(0x00)
DVI::Graphics.fill_rect(10, 10, 100, 50, 0xE0)
DVI::Graphics.commit
```

#### DVI::Graphics.width -> Integer

Return the current framebuffer width (640 or 320).

#### DVI::Graphics.height -> Integer

Return the current framebuffer height (480 or 240).

#### DVI::Graphics.set_resolution(width, height)

Switch graphics resolution. Valid pairs: (640, 480) and (320, 240). The
scale change is applied immediately for drawing and the HSTX is
reconfigured at the next VBlank.

#### DVI::Graphics.commit

Wait for VBlank, then copy the back buffer to the front buffer. Skips
the copy if the framebuffer has not been modified since the last commit.

#### DVI::Graphics.set_pixel(x, y, color)

Set a single pixel to the given RGB332 color.

#### DVI::Graphics.get_pixel(x, y) -> Integer

Return the RGB332 color at the given position.

#### DVI::Graphics.fill(color)

Fill the entire framebuffer with the given color.

#### DVI::Graphics.fill_rect(x, y, width, height, color)

Fill a rectangular region with the given color.

#### DVI::Graphics.draw_rect(x, y, width, height, color)

Draw a rectangle outline with the given color.

#### DVI::Graphics.fill_circle(cx, cy, r, color)

Fill a circle centered at (cx, cy) with radius r.

#### DVI::Graphics.draw_circle(cx, cy, r, color)

Draw a circle outline centered at (cx, cy) with radius r.

#### DVI::Graphics.fill_ellipse(cx, cy, rx, ry, color)

Fill an ellipse centered at (cx, cy) with radii (rx, ry).

#### DVI::Graphics.draw_ellipse(cx, cy, rx, ry, color)

Draw an ellipse outline centered at (cx, cy) with radii (rx, ry).

#### DVI::Graphics.fill_triangle(x0, y0, x1, y1, x2, y2, color)

Fill a triangle with the given vertices using scanline rasterization.

#### DVI::Graphics.fill_arc(cx, cy, r, start, stop, color)

Fill a pie-slice arc. Angles are in radians (0 = right, PI/2 = down).
Rendered as a triangle fan using sinf/cosf.

#### DVI::Graphics.draw_arc(cx, cy, r, start, stop, color)

Draw an arc outline. Angles are in radians.

#### DVI::Graphics.draw_line(x0, y0, x1, y1, color)

Draw a line using Bresenham's algorithm.

#### DVI::Graphics.draw_thick_line(x0, y0, x1, y1, thickness, color)

Draw a line with variable thickness.

#### DVI::Graphics.draw_text(x, y, text, color, font = FONT_8X8, wide_font = nil)

Draw a UTF-8 string at pixel position (x, y). Optional `wide_font`
enables CJK character rendering via Unicode-to-JIS lookup.

#### DVI::Graphics.text_width(text, font = FONT_8X8, wide_font = nil) -> Integer

Compute the pixel width of a string without rendering.

#### DVI::Graphics.font_height(font) -> Integer

Return the glyph height of a font in pixels.

#### DVI::Graphics.draw_image(data, x, y, w, h)

Blit an RGB332 image (byte string) at the given position.

#### DVI::Graphics.draw_image_masked(data, mask, x, y, w, h)

Blit an RGB332 image with a 1-bit transparency mask.

#### DVI::Graphics.set_blend_mode(mode)

Set the pixel compositing mode. Constants: `BLEND_REPLACE` (default),
`BLEND_ADD`, `BLEND_SUBTRACT`, `BLEND_MULTIPLY`, `BLEND_SCREEN`,
`BLEND_ALPHA`.

#### DVI::Graphics.set_alpha(value)

Set the global alpha value (0-255) for `BLEND_ALPHA` mode.

## C API

Defined in [dvi.h](../mrbgems/picoruby-dvi/include/dvi.h) and
[dvi_output.h](../mrbgems/picoruby-dvi/ports/rp2350/dvi_output.h).

### dvi_init_clock

```c
void dvi_init_clock(void);
```

Initialize system clock for DVI 640x480 output. Configures PLL to 250 MHz
and sets clk_hstx = clk_sys / 2 (125 MHz). Must be called before
`dvi_start_mode()`.

### dvi_start_mode

```c
void dvi_start_mode(dvi_mode_t mode);
```

Initialize HSTX, DMA, IRQ and start DVI output in the specified mode.
For `DVI_MODE_TEXT`, call `dvi_text_set_font()` before this function.
Must be called on Core 1.

### dvi_set_mode

```c
void dvi_set_mode(dvi_mode_t mode);
```

Switch display mode. The switch is applied at the next VBlank by the DMA
IRQ handler.

### dvi_set_blanking

```c
void dvi_set_blanking(bool enable);
```

Enable or disable DVI blanking for flash write safety. When enabled in text
mode, all active lines output black from a static SRAM buffer instead of
rendering from font data. Graphics mode is unaffected. Call
`dvi_wait_vsync()` after enabling to ensure blanking has taken effect.

### dvi_get_frame_count

```c
uint32_t dvi_get_frame_count(void);
```

Return the number of frames rendered since DVI output started.

### dvi_wait_vsync

```c
void dvi_wait_vsync(void);
```

Block until the next VBlank. See
[Cross-core vsync signaling](#cross-core-vsync-signaling) for details.

### dvi_get_framebuffer

```c
uint8_t *dvi_get_framebuffer(void);
```

Return a pointer to the drawing framebuffer. When double buffering is
enabled, returns the back buffer (PSRAM at 640x480, SRAM at 320x240).
Size depends on the runtime graphics scale: 307 KB at 640x480, 76.8 KB
at 320x240.

### dvi_graphics_get_width / dvi_graphics_get_height

```c
int dvi_graphics_get_width(void);
int dvi_graphics_get_height(void);
```

Return the current graphics resolution (640x480 or 320x240).

### dvi_set_graphics_scale

```c
void dvi_set_graphics_scale(int scale);
```

Set the runtime graphics scale (1 = 640x480, 2 = 320x240). The drawing
resolution updates immediately. HSTX reconfiguration is applied at the
next VBlank.

### dvi_graphics_commit

```c
void dvi_graphics_commit(void);
```

Wait for VBlank, then copy the back buffer to the front buffer. Skips
the copy if the framebuffer has not been modified since the last commit.

### dvi_text_set_font

```c
void dvi_text_set_font(const dvi_font_t *font);
```

Set the half-width font for text mode rendering. Caches all glyph rows
into the SRAM narrow row cache. Must be called before `dvi_start_mode()`.

### dvi_text_set_bold_font

```c
void dvi_text_set_bold_font(const dvi_font_t *font);
```

Set the bold half-width font. Cached into the upper half of the narrow
row cache (indices 256-511).

### dvi_text_set_wide_font

```c
void dvi_text_set_wide_font(const dvi_font_t *font);
```

Set the full-width (CJK) font. Glyphs are rendered into the per-position
glyph bitmap by `dvi_text_put_wide_char()` at write time.

### dvi_text_set_palette

```c
void dvi_text_set_palette(const uint8_t palette[16]);
```

Set all 16 text palette entries at once. Each entry is an RGB332 color.

### dvi_text_put_char

```c
void dvi_text_put_char(int col, int row, char ch, uint8_t attr);
```

Place a half-width character at the given grid position.

### dvi_text_put_string

```c
void dvi_text_put_string(int col, int row, const char *str, uint8_t attr);
```

Write a UTF-8 string starting at the given position. Handles both
half-width and full-width characters.

### dvi_text_put_wide_char

```c
void dvi_text_put_wide_char(int col, int row, uint16_t ch, uint8_t attr);
```

Place a full-width character (linear JIS index) at the given position.
Occupies two columns. Renders the glyph bitmap from flash font data.

### dvi_text_clear

```c
void dvi_text_clear(uint8_t attr);
```

Clear the entire text VRAM with spaces and the given attribute.

### dvi_text_clear_line

```c
void dvi_text_clear_line(int row, uint8_t attr);
```

Clear a single row with spaces and the given attribute.

### dvi_text_clear_range

```c
void dvi_text_clear_range(int col, int row, int width, uint8_t attr);
```

Clear a partial range within a single row.

### dvi_text_scroll_up

```c
void dvi_text_scroll_up(int lines, uint8_t fill_attr);
```

Scroll VRAM contents up by the specified number of lines. Bottom lines
are cleared with the given attribute.

### dvi_text_scroll_down

```c
void dvi_text_scroll_down(int lines, uint8_t fill_attr);
```

Scroll VRAM contents down by the specified number of lines. Top lines
are cleared with the given attribute.

### dvi_text_get_attr

```c
uint8_t dvi_text_get_attr(int col, int row);
```

Read the attribute byte of the cell at the given position.

### dvi_text_set_attr

```c
void dvi_text_set_attr(int col, int row, uint8_t attr);
```

Write the attribute byte of the cell at the given position.

### dvi_text_commit

```c
void dvi_text_commit(void);
```

Swap the back buffer to the front buffer at VBlank. Blocks until the
swap completes, then copies front buffer state to the new back buffer.
Text VRAM uses double buffering: Core 0 writes to the back buffer, and
Core 1 renders from the front buffer. This prevents tearing during
multi-cell updates such as scrolling or screen clearing.

## Hardware Configuration

### Pin Assignment

DVI output uses HSTX on GPIO 12-19, directly driving a DVI connector
without an external encoder IC. Pin definitions are in
[harucom_board.h](../include/boards/harucom_board.h).

| Constant | Pin | Function |
|----------|-----|----------|
| `HARUCOM_DVI_CLK_N_PIN` | GPIO 12 | TMDS clock - |
| `HARUCOM_DVI_CLK_P_PIN` | GPIO 13 | TMDS clock + |
| `HARUCOM_DVI_D0_N_PIN` | GPIO 14 | Lane 0 - (blue + sync) |
| `HARUCOM_DVI_D0_P_PIN` | GPIO 15 | Lane 0 + |
| `HARUCOM_DVI_D1_N_PIN` | GPIO 16 | Lane 1 - (green) |
| `HARUCOM_DVI_D1_P_PIN` | GPIO 17 | Lane 1 + |
| `HARUCOM_DVI_D2_N_PIN` | GPIO 18 | Lane 2 - (red) |
| `HARUCOM_DVI_D2_P_PIN` | GPIO 19 | Lane 2 + |
| `HARUCOM_DVI_HPD_PIN` | GPIO 11 | Hot plug detect |

### TMDS Lane Mapping

HSTX encodes RGB332 pixels into TMDS using the following configuration:

| Lane | Channel | NBITS | ROT |
|------|---------|-------|-----|
| 0 | Blue | 1 | 26 |
| 1 | Green | 2 | 29 |
| 2 | Red | 2 | 0 |

### RGB332 Color Encoding

Both display modes use RGB332 pixel format (1 byte per pixel).

| Bits | Channel | Values |
|------|---------|--------|
| 7-5 | Red | 0-7 |
| 4-2 | Green | 0-7 |
| 1-0 | Blue | 0-3 |

### Video Timing

640x480 @ 60 Hz (VGA DMT). The pixel clock is 25.0 MHz (-0.7% from
25.175 MHz standard), within typical display tolerance.

| Parameter | Pixels/Lines |
|-----------|--------------|
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

### Clock Configuration

Text mode rendering requires sys_clk > clk_hstx to reduce main SRAM bus
contention between DMA and CPU. A 2:1 ratio gives sufficient headroom.

| Parameter | Value |
|-----------|-------|
| clk_sys | 250 MHz |
| clk_hstx | 125 MHz (clk_sys / 2) |
| CLKDIV | 5 |
| N_SHIFTS | 5 |
| SHIFT | 2 bits |
| Pixel clock | 125 / 5 = 25.0 MHz |

PLL configuration:

```
VCO     = 12 MHz x 125 = 1500 MHz
sys_clk = 1500 / 6 / 1 = 250 MHz
VREG    = 1.15 V
```

Changing clk_sys does not affect clk_usb or clk_peri (both sourced from
PLL_USB at 48 MHz). UART baud rates remain correct.

## Architecture

### Display Modes

Two display modes are supported, selected via `dvi_set_mode()`:

**Graphics mode** (`DVI_MODE_GRAPHICS`): RGB332 framebuffer in main SRAM.
Resolution is set at compile time by `DVI_GRAPHICS_SCALE` (defined in
`dvi.h`, default 1). At scale 1, the framebuffer is 640x480 (300 KB)
with DMA_SIZE_32 pixel transfer (`ENC_N_SHIFTS=4`), matching text mode.
At scale 2, the framebuffer is 320x240 (75 KB) with 2x horizontal
scaling via DMA_SIZE_8 byte-lane replication (`ENC_N_SHIFTS=2`) and
vertical 2x by line doubling in the DMA IRQ handler.

**Text mode** (`DVI_MODE_TEXT`): text VRAM (106 columns x 37 rows) rendered
per-scanline at native 640x480 resolution. DMA uses DMA_SIZE_32 with
`ENC_N_SHIFTS=4` for 4 unique pixels per FIFO word. See
[dvi/text-mode-rendering.md](dvi/text-mode-rendering.md) for VRAM layout,
font caching, per-position glyph bitmap, and scanline renderer details.

### Core Assignment

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
| TIMER0_IRQ_2 | Timer | 0x00 | PIO-USB SOF timer |
| TIMER0_IRQ_0 | Timer | 0x20 | mruby task scheduler tick |
| TIMER0_IRQ_3 | Timer | 0x80 | Default alarm pool (sleep_ms) |

Core 1:

| IRQ | Source | Priority | Purpose |
|---|---|---|---|
| 11 | DMA_IRQ_1 | 0x00 | DMA scanline completion |

### Cross-core vsync signaling

`dvi_wait_vsync()` uses ARM SEV/WFE instead of WFI. WFI only wakes on
interrupts on the calling core's NVIC. SEV is a cross-core event signal
that wakes WFE on any core:

- DMA IRQ handler (core 1): increments `frame_count`, swaps text VRAM
  double-buffer pointers if `swap_pending`, then issues `SEV`
- `dvi_wait_vsync()` (any core): uses `WFE` to sleep until the event

### DMA Architecture

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

### Memory Layout

| Region | Size | Contents |
|---|---|---|
| Flash (XIP) | ~920 KB | Firmware, font data (~400 KB), mruby library |
| Main SRAM | ~177 KB | text_vram x2 (31.4 KB), narrow_row_cache (6.6 KB), line_buf (5.2 KB), screenbuf (300 KB, framebuffer / glyph_bitmap union), stacks, BSS |
| SCRATCH_X | ~3.6 KB | IRQ handler + render code |
| SCRATCH_Y | 4 KB | font_byte_mask (2 KB) + pico-sdk default stack (2 KB, unused after BSS stack switch) |
| PSRAM (QMI CS1) | 8 MB | mruby heap |

#### Main SRAM bank-offset technique

Main SRAM has 8 banks striped at 4-byte boundaries. Two buffers at offset N
share the same bank when N % 32 = 0.

Each line buffer is padded to 644 bytes (640 + 4). The word offset between
consecutive buffers is 161, so buf[i] maps to SRAM bank (161*i % 8).  With
8 buffers (2N for batch rendering), all buffers land on different banks
{0,1,2,3,4,5,6,7}, giving zero bank collisions between any pair of
simultaneously-active buffers.

### Stability Analysis

DVI output stability depends on avoiding bus contention and ensuring
Core 1 never accesses flash during flash write operations. See
[dvi/stability.md](dvi/stability.md) for QMI bus contention, Main SRAM
bus contention, flash write safety mechanisms, and diagnostic
instrumentation.

### Initialization Order

```c
dvi_init_clock();           // 250 MHz, VREG 1.15V
stdio_init_all();           // UART on core 0
psram_init();               // PSRAM timing at 375 MHz
dvi_text_set_font(...);     // configure fonts before DVI starts

multicore_launch_core1_with_stack(core1_dvi_entry, ...);
// core1_dvi_entry:
//   dvi_start_mode(DVI_MODE_TEXT)   -- registers DMA IRQ handler
//   copy vector table to SRAM       -- flash-independent interrupt dispatch
//   BASEPRI = 0x20, WFI loop        -- runs from SRAM

usb_host_init();            // PIO-USB host on core 0
run_mruby();                // mount filesystem, run Ruby scripts
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
