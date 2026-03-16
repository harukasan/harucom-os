# DVI output (720p via HSTX)

The Harucom Board outputs DVI video using the RP2350's built-in HSTX
(High-Speed Serial Transmit) peripheral. HSTX generates TMDS-encoded
differential signals on GPIO 12–19, directly driving a DVI connector
without an external encoder IC.

## System clock: 372 MHz

DVI 720p (1280×720 @ 60 Hz) requires a pixel clock of 74.25 MHz. HSTX
derives its clock from `clk_hstx`, which is configured as `clk_sys / 1`.
HSTX internally outputs 5 TMDS bits per clock (10× serialisation), so:

```
pixel clock = clk_hstx / 5 = 372 MHz / 5 = 74.4 MHz (+0.2% from 74.25 MHz)
```

The system clock must therefore be 372 MHz. This is set by
`dvi_init_clock()` in `mrbgems/picoruby-dvi/ports/rp2350/dvi_clock.c`.

### PLL configuration

| Parameter | Value |
|---|---|
| XOSC | 12 MHz |
| VCO | 12 MHz × 93 = 1116 MHz |
| Post-divider 1 | /3 |
| Post-divider 2 | /1 |
| sys_clk | 1116 / 3 / 1 = 372 MHz |
| VREG | 1.30 V (required for stable operation above 300 MHz) |

pico-sdk's `set_sys_clock_pll()` internally switches CLK_SYS to PLL_USB
(48 MHz) before reconfiguring PLL_SYS, then switches back. This prevents
glitches during PLL lock.

### QMI flash timing (CS0)

The flash clock divider must be increased before the PLL change:

| Clock | CLKDIV | SCK |
|---|---|---|
| 125 MHz (default) | 2 | 62.5 MHz |
| 372 MHz (DVI) | 4 | 93 MHz |

The flash maximum SCK is ~133 MHz, so CLKDIV=4 at 372 MHz keeps SCK well
within spec. The divider change is done inside `__not_in_flash_func` since
flash XIP timing must not change while executing from flash.

### PSRAM timing (CS1)

PSRAM (APS6404L) QMI timing is calculated dynamically by `set_psram_timing()`
in `psram.c`. The timing depends on the current `clk_sys` frequency:

| Clock | CLKDIV | SCK | MAX_SELECT | MIN_DESELECT |
|---|---|---|---|---|
| 125 MHz | 2 | 62.5 MHz | 15 | 7 |
| 372 MHz | 4 | 93 MHz | 46 | 19 |

Since `psram_init()` is called after `dvi_init_clock()`, the timing is
automatically correct for 372 MHz. No special handling is needed.

### USB PIO compatibility

PIO-based USB (Full Speed, 12 Mbps) requires the system clock to be an
integer multiple of 12 MHz for exact bit timing. 372 MHz = 12 MHz × 31,
so PIO dividers produce an exact 12 MHz clock. (For comparison, the
default 125 MHz is not an integer multiple of 12 MHz.)

### Peripheral clocks

Changing `clk_sys` does **not** affect:

- **clk_usb** — sourced from PLL_USB (48 MHz), unchanged
- **clk_peri** — sourced from PLL_USB (48 MHz) by default
- **PLL_USB** — not touched by `set_sys_clock_pll()`

UART baud rates are derived from `clk_peri`, so they remain correct after
the clock change.

## Initialization order

```c
dvi_init_clock();   // 125 → 372 MHz
psram_init();       // PSRAM timing calculated at 372 MHz
stdio_init_all();   // UART/USB CDC at 372 MHz peripheral clock
```

`dvi_init_clock()` must be called first because:

1. Flash CLKDIV must be set before the PLL change
2. PSRAM timing depends on the final system clock
3. UART baud rates are set during `stdio_init_all()`

## References

- [RP2350 datasheet §4.8 "HSTX"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [CEA-861 720p timing](https://en.wikipedia.org/wiki/720p)
- PicoLibSDK `_display/disphstx` — alternative HSTX DVI implementation
