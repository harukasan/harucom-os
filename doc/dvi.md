# DVI output (720p via HSTX)

The Harucom Board outputs DVI video using the RP2350's built-in
[HSTX][rp2350-hstx] (High-Speed Serial Transmit) peripheral.  HSTX
generates [TMDS][tmds]-encoded differential signals on GPIO 12-19,
directly driving a DVI connector without an external encoder IC.

[rp2350-hstx]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_hstx
[tmds]: https://en.wikipedia.org/wiki/Transition-minimized_differential_signaling

## Output format

### 720p timing

The output resolution is [1280x720 @ 60 Hz][cea-720p] (CEA-861 720p).
The standard pixel clock is 74.25 MHz; the actual output is 74.4 MHz
(+0.2%), which is within typical display tolerance.

[cea-720p]: https://en.wikipedia.org/wiki/720p

| Parameter | Pixels/Lines |
|---|---|
| H active | 1280 |
| H front porch | 110 |
| H sync width | 40 |
| H back porch | 220 |
| **H total** | **1650** |
| V active | 720 |
| V front porch | 5 |
| V sync width | 5 |
| V back porch | 20 |
| **V total** | **750** |

Sync polarity is positive for both HSYNC and VSYNC (1 = asserted).
Sync signals are encoded as [TMDS control symbols][tmds-ctrl] on lane 0
(blue channel): D0 carries HSYNC, D1 carries VSYNC.  Lanes 1 and 2
transmit CTRL_00 during blanking periods.

[tmds-ctrl]: https://en.wikipedia.org/wiki/Transition-minimized_differential_signaling#Control_tokens

### Framebuffer and scaling

The framebuffer is 640x360 pixels in [RGB332][rgb332] format (1 byte
per pixel, 230 KB).  HSTX hardware performs 2x horizontal scaling using
the shift expander: each byte is shifted twice (`ENC_N_SHIFTS=2`,
`ENC_SHIFT=8`), producing two identical TMDS pixels per DMA byte
transfer.  Vertical 2x scaling is done in software by the DMA IRQ
handler, which maps two consecutive output scanlines to the same
framebuffer row (`line >> 1`).

[rgb332]: https://en.wikipedia.org/wiki/List_of_monochrome_and_RGB_color_formats#8-bit_RGB_(3-3-2_bit)

The resulting output is 1280x720 pixels from a 640x360 source.

### RGB332 color encoding

| Bits | Channel | Values |
|---|---|---|
| 7-5 | Red | 0-7 |
| 4-2 | Green | 0-7 |
| 1-0 | Blue | 0-3 |

HSTX TMDS lane mapping (configured in `expand_tmds`):

| Lane | Channel | NBITS | ROT |
|---|---|---|---|
| 0 | Blue | 2 | 0 |
| 1 | Green | 3 | 29 |
| 2 | Red | 3 | 26 |

### GPIO pinout

HSTX outputs 0-7 appear on GPIO 12-19.  Each TMDS lane uses a
differential pair; the negative pin is inverted in the HSTX bit
configuration.

```
GP12 CK-   GP13 CK+   (TMDS clock, differential)
GP14 D0-   GP15 D0+   (Lane 0: blue + sync)
GP16 D1-   GP17 D1+   (Lane 1: green)
GP18 D2-   GP19 D2+   (Lane 2: red)
```

All pins are configured with `GPIO_DRIVE_STRENGTH_8MA` and
`GPIO_FUNC_HSTX` (function 0).

### HSTX serialization

| Parameter | Value |
|---|---|
| clk_hstx | 372 MHz (= clk_sys) |
| CLKDIV | 5 |
| N_SHIFTS | 5 |
| SHIFT | 2 bits |
| Bit clock | 372 / 5 x 5 x 2 = 744 Mbps |
| Pixel clock | 372 / 5 = 74.4 MHz |

The [command expander][rp2350-hstx-cmd] processes two opcodes from the
FIFO:

- `HSTX_CMD_RAW_REPEAT | N`: output a raw 30-bit sync word N times
  (used for blanking and sync periods)
- `HSTX_CMD_TMDS | N`: TMDS-encode N pixels from subsequent FIFO data
  (used for active video)

[rp2350-hstx-cmd]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_hstx

## Core assignment

DVI output runs on **core 1**, while the mruby VM and all application
code run on **core 0**.

```
Core 0: mruby VM, stdio, timers (default alarm pool)
Core 1: DVI output (HSTX + DMA), BASEPRI-isolated
```

This separation is required to prevent QMI bus contention from
disrupting the HSTX signal. See [QMI bus contention](#qmi-bus-contention)
below.

### Why mruby must run on core 0

The pico-sdk [default alarm pool][alarm-pool] is initialized during C
runtime startup (`runtime_init_default_alarm_pool`) and is permanently
bound to core 0.  The pool's core affinity is set by `get_core_num()`
at init time ([pico-sdk `time.c`][time.c]) and cannot be changed later.
Several subsystems depend on this:

[alarm-pool]: https://www.raspberrypi.com/documentation/pico-sdk/high_level.html#alarm
[time.c]: https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/common/pico_time/time.c#L287

- **`sleep_ms()` / `sleep_us()`**: creates a one-shot alarm on the
  default pool.  The alarm callback fires on core 0 via TIMER0_IRQ_3
  ([RP2350 datasheet section 12.5][rp2350-timer]).  If core 0 blocks
  timer IRQs (e.g. via BASEPRI), `sleep_ms` called from any core hangs
  indefinitely because the alarm never fires.
- **`stdio_usb_init()`**: asserts that `get_core_num()` matches the
  default alarm pool core ([pico-sdk `stdio_usb.c`][stdio-usb]).  It
  cannot be called from core 1.
- **mruby task scheduler**: `mrb_hal_task_init` registers an alarm IRQ
  on the calling core's NVIC.  Running `mrb_open` on core 0 ensures the
  task scheduler's alarm fires on core 0, where timer IRQs are not
  masked.

[rp2350-timer]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
[stdio-usb]: https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/rp2_common/pico_stdio_usb/stdio_usb.c#L195

### Why DVI must run on core 1

After `dvi_start()`, the DVI core sets `BASEPRI = 0x20` to block all
interrupts except DMA_IRQ_1 (priority 0x00).  This prevents
flash-resident IRQ handlers from executing on the DVI core.  See
[QMI bus contention](#qmi-bus-contention).

`dvi_start()` calls [`irq_set_exclusive_handler()`][irq-handler] from
core 1, which registers the DMA IRQ handler on core 1's NVIC.  On
Cortex-M33 dual-core RP2350, each core has its own
[NVIC][arm-nvic] (ISER, ISPR, etc.).  The DMA hardware interrupt line
is connected to both cores' NVICs, but only the core that has it
enabled via ISER will service it.

[irq-handler]: https://www.raspberrypi.com/documentation/pico-sdk/hardware.html#rpip1a48c7c2aa0d22bc4ee8f
[arm-nvic]: https://developer.arm.com/documentation/100230/latest/Nested-Vectored-Interrupt-Controller

### Interrupt layout

Each core has independent NVIC and masking registers (PRIMASK, BASEPRI).
The layout below was verified by reading NVIC ISER at runtime.

Core 0 NVIC (enabled interrupts):

| IRQ | Source | Priority | Purpose |
|---|---|---|---|
| 3 | TIMER0_IRQ_3 | default (0x80) | Default alarm pool (`sleep_ms`, mruby task scheduler) |
| 14 | USBCTRL_IRQ | default (0x80) | USB device controller |
| 51 | User IRQ | default (0x80) | USB CDC low-priority worker (`tud_task`) |

Core 1 NVIC (enabled interrupts):

| IRQ | Source | Priority | Purpose |
|---|---|---|---|
| 11 | DMA_IRQ_1 | 0x00 (highest) | DMA scanline completion |

IRQ numbers are defined in
[`rp2350.h`](https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/rp2350/hardware_regs/include/hardware/regs/intctrl.h).

All core 0 interrupts use `PICO_DEFAULT_IRQ_PRIORITY` (0x80).  The
mruby task scheduler uses `cpsid i` / `cpsie i` (PRIMASK) for critical
sections, which temporarily disables all core 0 interrupts.  This does
not affect core 1's DMA_IRQ_1 since each core has its own
[PRIMASK register][arm-primask].

[arm-primask]: https://developer.arm.com/documentation/100230/latest/Exception-model/Exception-entry-and-return

Core 1's [BASEPRI][arm-basepri] (0x20) blocks all priorities >= 0x20.
Since DMA_IRQ_1 is at priority 0x00, it passes through.  Any interrupt
that might be pending but not enabled on a core (e.g. DMA_IRQ_1 appears
in core 0's ISPR but is not in its ISER) is harmless.

[arm-basepri]: https://developer.arm.com/documentation/100230/latest/Exception-model/Exception-entry-and-return

### Cross-core vsync signaling

`dvi_wait_vsync()` cannot use WFI (Wait For Interrupt) when called from
a different core than the DMA IRQ.  [WFI][arm-wfi] only wakes when an
interrupt fires on the calling core's NVIC.  Since the DMA IRQ fires on
core 1, WFI on core 0 would never wake from a vsync event.

[arm-wfi]: https://developer.arm.com/documentation/100230/latest/Power-management

The solution uses the ARM [SEV/WFE][arm-sev-wfe] (Send Event / Wait For
Event) mechanism, which is a cross-core event notification independent
of interrupts:

[arm-sev-wfe]: https://developer.arm.com/documentation/100230/latest/Power-management

- **DMA IRQ handler (core 1)**: issues `SEV` after incrementing
  `frame_count` at each vsync
- **`dvi_wait_vsync()` (any core)**: uses `WFE` to sleep until the
  event arrives, then checks `frame_count`

WFE also wakes on interrupts, so it is a superset of WFI.  This means
`dvi_wait_vsync()` works correctly from any core.

## System clock: 372 MHz

DVI 720p (1280x720 @ 60 Hz) requires a pixel clock of 74.25 MHz. HSTX
derives its clock from `clk_hstx`, which is configured as `clk_sys / 1`.
HSTX internally outputs 5 TMDS bits per clock (10x serialisation), so:

```
pixel clock = clk_hstx / 5 = 372 MHz / 5 = 74.4 MHz (+0.2% from 74.25 MHz)
```

The system clock must therefore be 372 MHz. This is set by
`dvi_init_clock()` in `mrbgems/picoruby-dvi/ports/rp2350/dvi_clock.c`.

### PLL configuration

| Parameter | Value |
|---|---|
| XOSC | 12 MHz |
| VCO | 12 MHz x 93 = 1116 MHz |
| Post-divider 1 | /3 |
| Post-divider 2 | /1 |
| sys_clk | 1116 / 3 / 1 = 372 MHz |
| VREG | 1.35 V |

VREG is raised from the default 1.10 V to 1.35 V.  1.30 V is stable
for single-core operation, but dual-core mruby execution causes enough
voltage droop to destabilize PLL_SYS, disrupting HSTX output.
`vreg_disable_voltage_limit()` is required to unlock RP2350 voltages
above 1.30 V.

pico-sdk's `set_sys_clock_pll()` internally switches CLK_SYS to PLL_USB
(48 MHz) before reconfiguring PLL_SYS, then switches back. This prevents
glitches during PLL lock.

### QMI flash timing (CS0)

The flash clock divider must be increased before the PLL change:

| Clock | CLKDIV | SCK | Note |
|---|---|---|---|
| 125 MHz (default) | 2 | 62.5 MHz | Set by boot stage 2 |
| 372 MHz (DVI) | 8 | 46.5 MHz | Reduced to minimize QMI bus activity |

CLKDIV=4 (SCK = 93 MHz) is within flash spec (~133 MHz max), but the
mruby VM's large code footprint causes constant XIP cache misses.  At
CLKDIV=4, the high QMI transaction rate and the 8th harmonic of 93 MHz
(744 MHz) coinciding with the HSTX bit clock cause interference.
CLKDIV=8 reduces both the switching frequency and the QMI transaction
rate.

The divider change is done inside `__not_in_flash_func` since flash XIP
timing must not change while executing from flash.

### PSRAM timing (CS1)

PSRAM (APS6404L) QMI timing is calculated dynamically by
`set_psram_timing()` in `psram.c`. The PSRAM SCK is limited to 46 MHz
(`PSRAM_MAX_SCK_HZ`) to avoid harmonic interference with the HSTX bit
clock:

| Clock | CLKDIV | SCK | MAX_SELECT | MIN_DESELECT |
|---|---|---|---|---|
| 372 MHz | 8 | 46.5 MHz | 46 | 19 |

Since `psram_init()` is called after `dvi_init_clock()`, the timing is
automatically correct for 372 MHz.

### USB PIO compatibility

PIO-based USB (Full Speed, 12 Mbps) requires the system clock to be an
integer multiple of 12 MHz for exact bit timing. 372 MHz = 12 MHz x 31,
so PIO dividers produce an exact 12 MHz clock. (For comparison, the
default 125 MHz is not an integer multiple of 12 MHz.)

### Peripheral clocks

Changing `clk_sys` does **not** affect:

- **clk_usb**: sourced from PLL_USB (48 MHz), unchanged
- **clk_peri**: sourced from PLL_USB (48 MHz) by default
- **PLL_USB**: not touched by `set_sys_clock_pll()`

UART baud rates are derived from `clk_peri`, so they remain correct
after the clock change.

## QMI bus contention

The RP2350's [QMI][rp2350-qmi] (QSPI Memory Interface) bus is shared
between flash (CS0) and PSRAM (CS1).  QMI can only service one chip
select at a time.  The 16 KB [XIP cache][rp2350-xip] covers both CS0
and CS1.

[rp2350-qmi]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_qmi
[rp2350-xip]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_xip_cache

When the mruby VM on core 0 performs heavy PSRAM access (heap
allocation, GC), QMI CS1 transactions saturate the bus. If any code on
the DVI core accesses flash (via XIP cache miss), the flash fetch stalls
behind the PSRAM transactions.

The HSTX FIFO is 8 entries deep. At 720p pixel rate, this provides
approximately 215 ns of buffer. A single QMI PSRAM transaction takes
300+ ns, so even one stalled flash access on the DVI core can cause HSTX
FIFO underflow, corrupting the TMDS output and causing the display to
report "no signal".

### mruby VM in SRAM

The mruby VM dispatch loop (`vm.o`, ~27 KB) is placed in SRAM via
`.time_critical` sections. This eliminates XIP cache misses during the
VM's inner loop, which is the most frequently executed code. The
`scripts/vm_to_ram.sh` script extracts `vm.o` from `libmruby.a` and
renames its `.text.*` sections to `.time_critical.*`.

## Initialization order

```c
dvi_init_clock();     // 125 -> 372 MHz, VREG 1.35 V, QMI CLKDIV=8
stdio_init_all();     // UART/USB CDC on core 0
psram_init();         // PSRAM timing calculated at 372 MHz
draw_checkerboard();  // Fill framebuffer in SRAM

// Launch core 1: calls dvi_start(), enters BASEPRI+WFI idle loop
multicore_launch_core1_with_stack(core1_dvi_entry, ...);

// Core 0: run mruby VM with PSRAM heap
run_mruby();
```

`dvi_init_clock()` must be called first because:

1. Flash CLKDIV must be set before the PLL change
2. PSRAM timing depends on the final system clock
3. UART baud rates are set during `stdio_init_all()`

`dvi_start()` must be called from core 1 so that `irq_set_exclusive_handler()`
registers DMA_IRQ_1 on core 1's NVIC.

## DMA architecture

The DVI driver uses a per-scanline CMD-to-DATA [DMA][rp2350-dma]
architecture with double-buffered descriptor buffers.

[rp2350-dma]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_dma

- **DMA channel 0 (CMD)**: reads 4-word descriptors from a scanline
  buffer, writes to channel 1's [Alias 3 registers][dma-alias] via
  RING_WRITE
- **DMA channel 1 (DATA)**: executes transfers to the HSTX FIFO,
  chains back to CMD after each descriptor
- **NULL stop**: a zero-length descriptor that triggers DMA_IRQ_1 at
  the end of each scanline

[dma-alias]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_dma_ch_al

The IRQ handler starts the next pre-prepared buffer and builds
descriptors for the scanline two lines ahead.  Scanline command buffers
are in SCRATCH_Y; the IRQ handler code is in SCRATCH_X.  This
separation avoids I-bus / D-bus contention on the same
[SRAM bank][rp2350-sram].

[rp2350-sram]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_sram

Both DMA channels use high priority
([`bus_ctrl_hw->priority`][rp2350-busctrl]) and DREQ_HSTX pacing.
Pixel data is transferred as SIZE_8 (byte), with HSTX's
[shift expander][rp2350-hstx-expand] producing two identical TMDS
pixels per byte (horizontal 2x scaling: 640 framebuffer pixels to
1280 output pixels).

[rp2350-busctrl]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_busctrl
[rp2350-hstx-expand]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_hstx

## Memory layout

| Region | Size | Contents |
|---|---|---|
| Flash (XIP) | ~423 KB | Firmware code, mruby library (minus vm.o) |
| SRAM (main) | ~279 KB | Framebuffer (230 KB), mruby vm.o (27 KB), stacks, BSS |
| SRAM (SCRATCH_X) | ~2.4 KB | DMA IRQ handler code |
| SRAM (SCRATCH_Y) | ~2.2 KB | DMA scanline buffers, control words, state |
| PSRAM (XIP CS1) | 8 MB | mruby heap |

Core 0 stack is 32 KB (set via `__STACK_SIZE` linker symbol) to
accommodate the mruby compiler's deep C call stack.

## References

- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
  (HSTX: section 4.8, QMI: section 4.4, DMA: section 2.5, Bus fabric: section 2.1)
- [pico-sdk documentation](https://www.raspberrypi.com/documentation/pico-sdk/)
- [pico-sdk source (v2.2.0)](https://github.com/raspberrypi/pico-sdk/tree/2.2.0)
- [Arm Cortex-M33 Technical Reference Manual](https://developer.arm.com/documentation/100230/latest/)
  (NVIC, BASEPRI, PRIMASK, WFI/WFE/SEV)
- [CEA-861 720p timing](https://en.wikipedia.org/wiki/720p)
- [PicoLibSDK `_display/disphstx`](https://github.com/Panda381/PicoLibSDK):
  alternative HSTX DVI implementation
- [pico-examples `hstx/dvi_out_hstx_encoder`](https://github.com/raspberrypi/pico-examples/tree/master/hstx/dvi_out_hstx_encoder):
  reference HSTX DVI example
