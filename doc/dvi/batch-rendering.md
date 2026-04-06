# DVI batch scanline rendering

Active scanlines are batched N=4 per DMA IRQ.  Each batch renders 4
text scanlines and chains their DMA descriptors into a single transfer
sequence.

A single scanline period provides only 2,240 usable cycles for
rendering (1,600 H-blanking + 640 FIFO margin from the 8-entry HSTX
FIFO).  Batching 4 scanlines extends the budget to 32,000 cycles,
providing ~24,500 cycles of headroom.

480 active lines / 4 = 120 batches with no remainder.  Blanking lines
remain single (45 IRQs: 10 VFP + 2 VSYNC + 33 VBP).  Total: 165 IRQs
per frame.

## Design

### Line buffers: 2N = 8

`line_buf[8][644]` (5,152 bytes).

2N buffers are required because double-buffered descriptors mean the
DMA reads from N=4 buffers while the CPU simultaneously renders N=4
new lines into separate buffers.  CPU rendering (~29 usec for 4 lines
at 250 MHz) finishes before DMA finishes reading the first buffer
(~32 usec), so the DMA-read and CPU-write buffer sets must be
completely disjoint.

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

Blanking layout (8 words): sync group + NULL stop.

### CMD channel RING_WRITE

RING_WRITE = 4 (2^4 = 16 bytes).  This controls the write destination
wrapping on DATA channel's AL3 registers (ctrl, write_addr,
trans_count, read_addr_trig), not the read source buffer size.  The
CMD channel reads sequentially through the descriptor buffer, 4 words
at a time, writing to the same 4 AL3 registers each time via ring wrap.

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

Mode switching (`next_mode`) is checked at VSync pulse start (line 490).

## Memory

| Component | Size |
|---|---|
| line_buf | 5,152 B |
| dma_scanline_buf | 288 B |
| **Total** | **5,440 B** |

## Measured performance

| Workload | Per-line (rl) | Batch total (bt) | Headroom (of 32,000) |
|----------|---------------|------------------|----------------------|
| Narrow-only | ~2,050 | ~8,200 | ~23,800 |
| Mixed (narrow + wide) | ~2,200 | ~8,800 | ~23,200 |

SCRATCH_X usage: 3,668 / 4,096 bytes (89.6%).
