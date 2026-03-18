# DVI batch scanline rendering

This document describes a planned optimization to batch multiple scanlines
per DMA IRQ, increasing the render headroom from ~400 to ~24,500 cycles.

## Problem

The current architecture renders one text scanline per DMA IRQ.  The render
budget is tight:

| Parameter | Cycles |
|---|---|
| H blanking (160 px at 10 sys_clk/px_clk) | 1,600 |
| FIFO margin (8 entries at 80 cycles each) | 640 |
| **Total budget** | **2,240** |
| Typical render (uniform-attr narrow) | ~1,837 |
| Spike render (mixed-attr + wide) | ~2,318 |
| **Headroom (typical)** | **~403** |
| **Headroom (spike)** | **-78 (exceeds budget)** |

Spikes are absorbed by the HSTX FIFO, but the margin is thin.  PSRAM
access from the mruby VM on Core 0 (GC, string allocation) can cause
additional Main SRAM bus contention that pushes the render past the FIFO
budget.

## Proposed solution: batch N scanlines per IRQ

Instead of one IRQ per scanline, chain N scanlines of DMA descriptors and
render all N lines in a single IRQ handler invocation.

### Budget comparison (N=4)

| | Current (N=1) | Batched (N=4) |
|---|---|---|
| Budget | 8,000 cycles | 32,000 cycles |
| Render | ~1,837 cycles | ~7,400 cycles |
| IRQ overhead | ~74 cycles | ~74 cycles (once) |
| **Headroom** | **~400 cycles** | **~24,500 cycles** |

The budget scales linearly with N, but the render is slightly sub-linear
(IRQ overhead is amortized).  Even worst-case spikes (4 x 2,500 = 10,000
cycles) leave >20,000 cycles of headroom.

### N=4 is a natural fit

480 active lines / 4 = 120 batches with no remainder.  The VBlank boundary
aligns cleanly with batch boundaries.

## Implementation plan

### 1. Expand line buffers

Current: `line_buf[2][644]` (1,288 bytes, double-buffered).

Batched: `line_buf[N+1][644]` where N+1 buffers allow N rendered lines
plus one being DMA'd.  For N=4: `line_buf[5][644]` = 3,220 bytes
(+1,932 bytes).

The SRAM bank-offset technique must be extended.  Currently stride = 644
bytes gives bank offset = 1 between buf[0] and buf[1].  With 5 buffers,
ensure no two simultaneously-active buffers (one DMA read, one CPU write)
share the same bank.

### 2. Expand DMA descriptor buffers

Current: `dma_scanline_buf[2][12]` (12 words per scanline, double-buffered).

Batched: each batch descriptor contains N scanlines of hsync+pixel groups
plus one NULL stop group.  For N=4:

```
Group 0:  hsync cmd (sync) + pixel data line 0
Group 1:  hsync cmd (sync) + pixel data line 1
Group 2:  hsync cmd (sync) + pixel data line 2
Group 3:  hsync cmd (sync) + pixel data line 3
Group 4:  NULL stop (triggers IRQ)
```

Each pixel group is 8 words (ctrl, fifo, count, src for sync and pixel).
Total: N x 8 + 4 (stop) = 36 words for N=4.  Double-buffered: 72 words
(288 bytes, up from current 96 bytes).

The CMD channel RING_WRITE size must be adjusted to match the new
descriptor buffer size.

### 3. Modify IRQ handler

```
dma_irq_handler:
    trigger next batch descriptor
    for i in 0..N-1:
        render scanline (cur_line + 2 + i) into line_buf[next_free + i]
    advance cur_line by N
    if VBlank: frame_count++, check next_mode
```

The render loop runs N times per IRQ.  Each render writes to a different
line buffer.  The total render time (~7,400 cycles for N=4) is well within
the batch budget (32,000 cycles).

### 4. Handle VBlank boundary

With N=4 and 480 active lines, the last batch renders lines 476-479.
The next IRQ builds VBlank descriptors (blank/vsync lines) which do not
need rendering.  VBlank batches can use a simplified descriptor chain.

Mode switching (`next_mode`) is checked at VSync pulse start, same as
current implementation.

### 5. Handle text mode line optimization

The fast path (`line >= 2`, updates only `buf[7]`) must be adapted for
batch descriptors.  Within each batch, only the first occurrence of a
line needs full descriptor build; subsequent lines in the same batch can
use the fast path relative to their position in the descriptor buffer.

## Memory cost

| Component | Current | N=4 | Delta |
|---|---|---|---|
| line_buf | 1,288 B | 3,220 B | +1,932 B |
| dma_scanline_buf | 96 B | 288 B | +192 B |
| **Total** | **1,384 B** | **3,508 B** | **+2,124 B** |

Main SRAM usage: ~182 KB / 512 KB.  The additional 2 KB is well within
available memory.

## Risks

- **SRAM bank collisions**: more line buffers increase the chance of DMA
  read and CPU write hitting the same SRAM bank.  Stride padding must be
  tuned for the new buffer count.

- **Descriptor complexity**: the CMD-to-DATA DMA chain becomes more
  complex.  RING_WRITE alignment and descriptor layout must be carefully
  validated.

- **Mode switching granularity**: mode switches can only occur at batch
  boundaries during VBlank, which is the same as current behavior.

- **SCRATCH_X pressure**: the IRQ handler grows slightly due to the batch
  loop.  Current usage is 85.7% (3,512 / 4,096 bytes).  The batch loop
  adds ~50-100 bytes, staying within the 4 KB limit.
