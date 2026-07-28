// DVI clock initialization for 640x480 output.
//
// Overclocks sys_clk to 252 MHz and sets clk_hstx = sys_clk / 2 = 126 MHz.
// The HSTX serializer uses CLKDIV=5, so pixel clock = 126 / 5 = 25.2 MHz
// (VESA DMT specifies 25.175 MHz; 25.2 MHz is +0.1%, well within monitor
// tolerance, and yields exactly 60.000 Hz refresh).
//
// 252 MHz is a multiple of 12 MHz, which Pico-PIO-USB requires:
// pio_usb_host_init() derives its four PIO clock dividers (48/96/6/12 MHz
// targets) from clk_sys, and only integer ratios give jitter-free USB bit
// timing. USB hubs are repeaters with tight jitter tolerance, so a
// non-multiple clock breaks hub operation even when direct HID devices
// still work.
//
// The 2:1 sys_clk:hstx ratio gives the CPU twice as many cycles between
// DMA bus transactions, reducing SRAM contention during text rendering.
// sys_clk is 10x the pixel clock, so each scanline provides 8,000 CPU
// cycles regardless of the absolute frequency.
//
// Peripherals (UART, USB PHY) are unaffected: clk_peri stays on pll_usb
// (48 MHz). QMI flash clock stays within spec: SCK = 252 / 2 = 126 MHz
// (< 133 MHz max). PSRAM timing is recomputed from clk_sys by
// set_psram_timing().

#include "dvi_output.h"

#include "hardware/clocks.h"
#include "hardware/pll.h"
#include "hardware/vreg.h"
#include "pico/stdlib.h"

void
dvi_init_clock(void)
{
  // Raise VREG voltage for stable operation at 252 MHz.
  vreg_set_voltage(VREG_VOLTAGE_1_15);
  sleep_ms(10);

  // Reconfigure PLL: 12 MHz * 126 = 1512 MHz VCO, / 6 / 1 = 252 MHz.
  set_sys_clock_pll(1512000000, 6, 1);

  // clk_hstx = sys_clk / 2 = 126 MHz -> pixel clock = 25.2 MHz.
  clock_configure(clk_hstx, 0, CLOCKS_CLK_HSTX_CTRL_AUXSRC_VALUE_CLK_SYS, 252000000, 126000000);
}
