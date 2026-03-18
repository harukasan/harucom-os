# DVI batch scanline rendering

This document describes the batch scanline rendering optimization that
chains multiple scanlines per DMA IRQ, increasing the render headroom
from ~400 to ~24,500 cycles.

## Problem

The previous architecture rendered one text scanline per DMA IRQ.  The
render budget was tight:

| Parameter | Cycles |
|---|---|
| H blanking (160 px at 10 sys_clk/px_clk) | 1,600 |
| FIFO margin (8 entries at 80 cycles each) | 640 |
| **Total budget** | **2,240** |
| Typical render (uniform-attr narrow) | ~1,837 |
| Spike render (mixed-attr + wide) | ~2,318 |
| **Headroom (typical)** | **~403** |
| **Headroom (spike)** | **-78 (exceeds budget)** |

Spikes were absorbed by the HSTX FIFO, but the margin was thin.  PSRAM
access from the mruby VM on Core 0 (GC, string allocation) could cause
additional Main SRAM bus contention that pushed the render past the FIFO
budget.

## Solution: batch N=4 scanlines per IRQ

Instead of one IRQ per scanline, chain N scanlines of DMA descriptors
and render all N lines in a single IRQ handler invocation.

### Budget comparison (N=4)

| | Previous (N=1) | Batched (N=4) |
|---|---|---|
| Budget | 8,000 cycles | 32,000 cycles |
| Render | ~1,837 cycles | ~7,400 cycles |
| IRQ overhead | ~74 cycles | ~74 cycles (once) |
| **Headroom** | **~400 cycles** | **~24,500 cycles** |

The budget scales linearly with N, but the render is slightly sub-linear
(IRQ overhead is amortized).  Even worst-case spikes (4 x 2,500 = 10,000
cycles) leave >20,000 cycles of headroom.

### N=4 is a natural fit

480 active lines / 4 = 120 batches with no remainder.  The VBlank
boundary aligns cleanly with batch boundaries.

### IRQ frequency

Active lines: 120 batches of 4.  Blanking lines: 45 single-line IRQs
(10 VFP + 2 VSYNC + 33 VBP).  Total: 165 IRQs per frame (down from
525).

## Design

### Line buffers: 2N = 8

`line_buf[8][644]` (5,152 bytes).

N+1 = 5 buffers would be **unsafe**: with double-buffered descriptors,
when we trigger the pre-prepared batch (DMA reads N=4 buffers), we
simultaneously render N=4 new lines into separate buffers for the next
batch.  CPU rendering (~29 usec for 4 lines at 250 MHz) finishes before
DMA finishes reading the first buffer (~32 usec), so the 4 DMA-read
buffers and 4 CPU-write buffers must be completely disjoint.

SRAM bank analysis for 8 buffers at stride 644 bytes (161 words):

| Buffer | Word offset | Bank (offset % 8) |
|---|---|---|
| 0 | 0 | 0 |
| 1 | 161 | 1 |
| 2 | 322 | 2 |
| 3 | 483 | 3 |
| 4 | 644 | 4 |
| 5 | 805 | 5 |
| 6 | 966 | 6 |
| 7 | 1127 | 7 |

All 8 buffers map to different SRAM banks.  Zero bank collisions.

### DMA descriptor buffers

`dma_scanline_buf[2][36]` (288 bytes, double-buffered).

Active batch layout (36 words):

```
buf[ 0.. 3]: sync group   line 0  (ctrl_sync, fifo, hsync_count, &hsync_cmd)
buf[ 4.. 7]: pixel group  line 0  (ctrl_text_pixel, fifo, pixel_count, &line_buf)
buf[ 8..15]: sync + pixel  line 1
buf[16..23]: sync + pixel  line 2
buf[24..31]: sync + pixel  line 3
buf[32..35]: NULL stop     (ctrl_stop, 0, 0, 0)
```

Blanking layout (8 words): sync group + NULL stop, same as before.

### CMD channel RING_WRITE

RING_WRITE = 4 (2^4 = 16 bytes) is **unchanged**.  It controls the
write destination wrapping on DATA channel's AL3 registers (ctrl,
write_addr, trans_count, read_addr_trig), not the read source buffer
size.  The CMD channel reads sequentially through the descriptor buffer,
4 words at a time, writing to the same 4 AL3 registers each time via
ring wrap.

### Fast path

Full descriptor builds (all 36 words) occur only for the first two
active batches per frame (`first_line < BATCH_SIZE * 2`), initializing
both double-buffered descriptor buffers.  Subsequent batches update only
the 4 line buffer pointers at offsets 7, 15, 23, 31.

### IRQ handler

```
dma_irq_handler:
    trigger next pre-prepared batch descriptor
    cur_line = buf_first_line[triggered buffer]
    batch_size = (active) ? BATCH_SIZE : 1
    if cur_line == 480: VBlank (frame_count++, sev)
    if cur_line == 490: mode switch check
    build_start = cur_line + batch_size
    prepare_batch_dma(free buffer, build_start)
```

### VBlank boundary

The last active batch renders lines 476-479.  The next IRQ builds a
single blanking line (line 480), signaling VBlank.  Blanking lines use
the simpler 8-word descriptor (no rendering).

Mode switching (`next_mode`) is checked at VSync pulse start (line 490),
same as the previous implementation.

## Memory cost

| Component | Previous | N=4 | Delta |
|---|---|---|---|
| line_buf | 1,288 B | 5,152 B | +3,864 B |
| dma_scanline_buf | 96 B | 288 B | +192 B |
| **Total** | **1,384 B** | **5,440 B** | **+4,056 B** |

Main SRAM usage: ~192 KB / 512 KB.  The additional 4 KB is well within
available memory.

## Diagnostics

The following diagnostic variables (under `DVI_DIAGNOSTICS`) support
validation:

- `dvi_irq_interval_min/max`: IRQ-to-IRQ interval in cycles.  Expected
  ~32,000 for active batches, ~8,000 for blanking lines.
- `dvi_render_max/min/last_cycles`: per-line render timing within
  batches.
- `dvi_irq_max_cycles`: total IRQ handler time including batch render.
- `dvi_fifo_empty_count`: must remain 0.
- `dvi_fifo_min_level`: minimum HSTX FIFO level at IRQ entry.

## SCRATCH_X usage

Previous: 3,512 / 4,096 bytes (85.7%).  After batch rendering: 3,632 /
4,096 bytes (88.7%).  Delta: +120 bytes for the batch loop and
`buf_first_line` tracking.
