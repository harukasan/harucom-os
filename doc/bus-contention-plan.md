# Bus contention mitigation for mruby VM and DVI output

When the mruby VM performs heavy memory operations (allocation, GC, large
data processing), bus contention can affect DVI output stability.  This
document describes three approaches to reduce contention.

## Background

Core 0 runs the mruby VM.  Its heap is in PSRAM (8 MB, QMI CS1,
memory-mapped at 0x11000000 through XIP cache).  Core 1 runs the DVI
scanline renderer, reading text VRAM and font cache from main SRAM and
writing pixel data to line buffers in SCRATCH_Y.

Contention occurs in two paths:

1. **Main SRAM bus**: Core 0 (stack, VRAM writes) vs Core 1 (VRAM reads,
   font cache reads) vs DMA (line buffer reads from SCRATCH_Y).
2. **QMI**: Heavy PSRAM access from Core 0 can stall the XIP subsystem.
   Core 1 does not access QMI, but flash XIP cache misses on Core 0
   (e.g. mruby bytecode fetch) are blocked while PSRAM holds the QMI bus.

Current mitigations:

- DMA channels have high priority (`channel_config_set_high_priority`)
- DMA has bus fabric priority (`BUSCTRL_BUS_PRIORITY_DMA_W_BITS |
  DMA_R_BITS`)
- Core 1 is BASEPRI-isolated (only DMA_IRQ_1 at priority 0x00 passes)
- Line buffers and DMA descriptors are in SCRATCH_Y (separate bus port)
- IRQ handler code is in SCRATCH_X (separate bus port)
- Per-position glyph bitmap and narrow row cache eliminate Core 1 flash
  access during rendering

## Plan 1: BUSCTRL PROC1 priority

Give Core 1 (DVI renderer) bus fabric priority over Core 0 (mruby VM).

### Current state

```c
// dvi_output.c:1086
bus_ctrl_hw->priority =
    BUSCTRL_BUS_PRIORITY_DMA_W_BITS | BUSCTRL_BUS_PRIORITY_DMA_R_BITS;
```

Only DMA has elevated priority.  Both cores have default (low) priority,
so when Core 0 and Core 1 request the same SRAM bank simultaneously,
arbitration is round-robin.

### Change

```c
bus_ctrl_hw->priority =
    BUSCTRL_BUS_PRIORITY_DMA_W_BITS | BUSCTRL_BUS_PRIORITY_DMA_R_BITS |
    BUSCTRL_BUS_PRIORITY_PROC1_BITS;
```

`BUSCTRL_BUS_PRIORITY_PROC1_BITS` (bit 4) elevates Core 1 on the bus
fabric.  When Core 0 and Core 1 contend for the same SRAM bank, Core 1
wins immediately instead of waiting for round-robin.

### Effect

- Core 1's VRAM and font cache reads complete without stalling, even
  during heavy Core 0 SRAM activity.
- Core 0 may experience slightly longer SRAM access latency under
  contention, but this only affects mruby performance, not DVI stability.
- No effect on QMI/PSRAM contention (QMI is accessed only by Core 0).

### Measurement

Use the existing bus performance counters (SRAM9 contested/access) and
FIFO empty count to compare before and after.  Expected result: fewer
FIFO empty events during heavy mruby workloads.

## Plan 2: QMI MAX_SELECT reduction

Shorten the maximum CS assertion duration for PSRAM to create gaps in
QMI bus occupancy.

### Current state

```c
// psram.c:set_psram_timing()
uint8_t max_select = PSRAM_MAX_SELECT_FS / fs_per_cycle;
```

At 250 MHz sys_clk: `fs_per_cycle` = 4,000,000 fs, so `max_select` =
125,000,000 / 4,000,000 = 31.  This means CS1 can stay asserted for
31 x 64 = 1,984 sys_clk cycles (~7.9 us), close to the APS6404L tCEM
limit of 8 us.

During a long sequential PSRAM read (e.g. GC heap scan), the QMI holds
CS1 asserted for up to 1,984 cycles continuously.  Any flash XIP cache
miss during this window must wait for the PSRAM transaction to reach a
page boundary or MAX_SELECT limit before flash can be serviced.

### Change

Reduce MAX_SELECT to a shorter value, for example 8 (512 sys_clk cycles,
~2 us) or 4 (256 cycles, ~1 us).  This forces the QMI to periodically
deassert CS1 and service any pending flash (CS0) requests.

```c
// Option A: cap at 8 (512 cycles, ~2 us)
if (max_select > 8) max_select = 8;

// Option B: cap at 4 (256 cycles, ~1 us)
if (max_select > 4) max_select = 4;
```

### Trade-off

- **Shorter MAX_SELECT**: More frequent CS deassert/reassert cycles.
  Each cycle costs SELECT_HOLD (3 cycles) + MIN_DESELECT (7 cycles at
  250 MHz) + command overhead (8 QPI prefix + 24 address + 24 dummy =
  14 SCK cycles at CLKDIV=2 = 28 sys_clk cycles) per re-select.
  Total overhead per re-select: ~38 sys_clk cycles.
- **PSRAM throughput impact**: At MAX_SELECT=8 (512 cycles), re-select
  happens every 512 cycles, adding ~7% overhead to sequential reads.
  At MAX_SELECT=4 (256 cycles), ~15% overhead.
- **Benefit**: Flash XIP cache misses are serviced within at most
  MAX_SELECT x 64 cycles, reducing worst-case stall from ~8 us to
  ~2 us (MAX_SELECT=8) or ~1 us (MAX_SELECT=4).

### Measurement

Add a flash cache miss counter or measure mruby bytecode execution
latency variance.  The DVI diagnostic timer already tracks FIFO empty
events.  If flash XIP misses during PSRAM-heavy workloads are causing
Core 0 stalls that delay VRAM updates or timer callbacks, shorter
MAX_SELECT should reduce the frequency.

## Plan 3: mruby heap size limit

Restrict the PSRAM heap size passed to mruby to reduce GC scan range
and improve XIP cache effectiveness.

### Current state

```c
// main.c:167
mrb_state *mrb = mrb_open_with_custom_alloc(heap_pool_g, heap_size_g);
```

`heap_size_g` is the full PSRAM size (8 MB).  The mruby GC must scan all
allocated objects across this range.  The XIP cache is 16 KB (hardware
fixed), so scanning 8 MB of heap causes extreme cache thrashing:
16 KB / 8 MB = 0.2% cache coverage.

### Change

Pass a smaller heap size to mruby:

```c
// Limit heap to 1 MB (adjust based on actual application needs)
size_t mruby_heap_size = 1 * 1024 * 1024;
if (mruby_heap_size > heap_size_g) mruby_heap_size = heap_size_g;
mrb_state *mrb = mrb_open_with_custom_alloc(heap_pool_g, mruby_heap_size);
```

### Effect

- **GC scan range**: Reduced from 8 MB to 1 MB (or chosen limit).
  GC walks only live objects within the heap, so a smaller heap means
  fewer cache lines evicted during GC.
- **XIP cache hit rate**: 16 KB / 1 MB = 1.6% coverage (8x better than
  16 KB / 8 MB).  Temporal locality within the working set improves
  because the same cache lines are revisited more often.
- **QMI traffic**: Proportionally reduced during GC.  Fewer cache misses
  means fewer QMI transactions.
- **Application impact**: The application must fit within the reduced
  heap.  Monitor `mrb_open` / allocation failures and adjust the limit
  upward if needed.

### Choosing the right size

Start with 512 KB or 1 MB and run the target application.  If the
application runs without allocation failures, the limit is sufficient.
The remaining PSRAM can be reserved for other uses (framebuffer, file
system cache, audio buffers).

### Measurement

Compare DVI FIFO empty events and GC pause duration (if measurable)
with 8 MB vs 1 MB heap.  The diagnostic timer output shows frame count
and FIFO empty count per second, which should show improvement during
GC-heavy workloads.
