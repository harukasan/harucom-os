# DVI Stability Analysis

DVI output on Core 1 must produce continuous, glitch-free scanline data.
Any stall in the DMA IRQ handler causes HSTX FIFO underflow, resulting
in visible artifacts or monitor sync loss. This document covers the
contention sources and techniques that keep DVI output stable.

## QMI Bus Contention

The QMI bus is shared between flash (CS0) and PSRAM (CS1). The 16 KB XIP
cache covers both chip selects. When the mruby VM alternates between flash
code and PSRAM data, the XIP cache thrashes, generating heavy QMI traffic.

The narrow row cache and per-position glyph bitmap keep all render-time
font reads in SRAM, so the render path has no flash access. Text mode is
stable regardless of mruby VM activity.

## DMA Bus Priority

The DMA data channel is configured with `channel_config_set_high_priority`
to give it elevated bus arbitration priority. This ensures DMA reads from
line buffers are not delayed by Core 0's SRAM accesses. Without high
priority, CPU-intensive mruby VM operations could starve the DMA and cause
FIFO underflow.

## BASEPRI Interrupt Isolation

Core 1 sets `BASEPRI = 0x20` after DVI initialization, blocking all
interrupts with priority >= 0x20. Only DMA_IRQ_1 (priority 0x00) passes
through. This prevents flash-resident IRQ handlers (timers, USB) from
executing on Core 1, which would stall on flash access and cause FIFO
underflow.

## Main SRAM Bus Contention

At sys_clk = clk_hstx (1:1 ratio), DMA and CPU compete for main SRAM bus
bandwidth on every cycle. The 2:1 ratio (250 MHz sys_clk, 125 MHz clk_hstx)
reduces contention enough for the render to fit within the scanline budget.

Measured per-line render cycles at 250 MHz:

| Workload | Cycles |
|----------|--------|
| Narrow-only | ~2,050 |
| Mixed (narrow + wide) | ~2,200 |

The following techniques keep the per-line render time low:

1. **DMA descriptor buffers in Main SRAM**: placed in Main SRAM instead
   of SCRATCH_Y to avoid contention with font_byte_mask lookups during
   rendering. CMD DMA reads these in brief bursts (4 words per group).

2. **font_byte_mask table in SCRATCH_Y**: maps font byte (0-255) to
   pre-computed (mask_hi, mask_lo) pairs. A single ldrd from SRAM9
   (separate bus port) avoids Main SRAM contention with DMA.
   256 entries x 8 bytes = 2 KB.

3. **DMA trigger reordering**: the IRQ handler triggers the next
   pre-prepared descriptor buffer immediately after acknowledgment, before
   diagnostics.

4. **Per-position glyph bitmap**: all full-width font reads come from SRAM
   (glyph data rendered at write time), avoiding flash XIP access entirely.
   See [text-mode-rendering.md](text-mode-rendering.md) for details.

5. **Set-time pre-computation**: bold narrow offset stored in `cell.ch` at
   write time (bit 8), eliminating a runtime branch from the render loop.

7. **Load-latency interleaving**: next nibble address computed during the
   2-cycle ldr bubble in the wide sub-path.

## Flash Write Safety

Flash erase and program operations temporarily disable XIP, making the
entire flash chip inaccessible to all cores. Without protection, Core 1
would fault when the DMA IRQ handler dispatches or when the WFI loop
resumes instruction fetch from flash.

Three mechanisms ensure Core 1 is not affected during flash operations:

1. **DVI blanking with VSync synchronization**: The flash disk driver calls
   `dvi_set_blanking(true)` followed by `dvi_wait_vsync()` before flash
   operations. The VSync wait ensures that blanking has taken effect (at
   least one blank frame has been output) before XIP is disabled. In text
   mode, the DMA IRQ handler outputs all-black lines from a static SRAM
   buffer instead of rendering from font data (which may reference flash
   .rodata). Graphics mode is unaffected because the framebuffer is
   entirely in SRAM. After the flash operation, `dvi_set_blanking(false)`
   followed by `dvi_wait_vsync()` ensures the DMA descriptors have fully
   transitioned back to normal rendering before the next write.

2. **VTOR in SRAM**: After `dvi_start_mode()` registers the DMA IRQ
   handler, `core1_dvi_entry` copies the vector table to SRAM and updates
   the VTOR register. Without this, the CPU would read handler addresses
   from the flash vector table when an interrupt fires, faulting while XIP
   is disabled.

3. **SRAM-resident WFI loop**: `core1_dvi_entry` is marked
   `__not_in_flash_func` so the WFI loop executes from SRAM. Without this,
   Core 1 would resume instruction fetch from flash after waking from WFI,
   faulting while XIP is disabled.

Core 0 disables its own interrupts (`save_and_disable_interrupts`) during
`flash_range_erase` and `flash_range_program` to prevent flash-resident IRQ
handlers from running on the core performing the flash operation.

### PSRAM inaccessibility during flash programming

The source buffer for `flash_range_program` must be in SRAM, not PSRAM.
`flash_range_program` puts the QMI controller into flash command mode (CS0),
which makes PSRAM (QMI CS1) inaccessible. The flash disk driver uses a
static 4 KB SRAM buffer (`FLASH_SECTOR_SIZE` bytes) and processes one
sector at a time. For multi-sector writes, each sector is copied from PSRAM
to the SRAM buffer and programmed individually.

## Diagnostic Instrumentation

The driver includes counters readable via
[dvi_output.h](../../mrbgems/picoruby-dvi/ports/rp2350/dvi_output.h)
(gated by `DVI_DIAGNOSTICS`):

- `dvi_irq_max_cycles`: DWT cycle count for prepare_batch_dma
- `dvi_render_max/min/last_cycles`: per-line render timing
- `dvi_batch_render_max/last_cycles`: total batch render time (sum of
  BATCH_SIZE line renders)
- `dvi_irq_interval_min/max`: IRQ-to-IRQ interval in cycles
- `dvi_fifo_empty_count`: HSTX FIFO empty events at IRQ entry
- `dvi_fifo_empty_log[]`: scanline numbers of the last 8 empty events
- `dvi_fifo_min_level`: minimum FIFO level per diagnostic interval
- `dvi_read_bus_counters()`: SRAM9 contested/total access counts
