// DVI clock initialization for 640x480 output.
//
// Overclocks sys_clk to 250 MHz and sets clk_hstx = sys_clk / 2 = 125 MHz.
// The HSTX serializer uses CLKDIV=5, so pixel clock = 125 / 5 = 25 MHz.
//
// The 2:1 sys_clk:hstx ratio gives the CPU twice as many cycles between
// DMA bus transactions, reducing SRAM contention during text rendering.
// At 250 MHz, each scanline provides 8,000 CPU cycles (vs 4,000 at 125 MHz).
//
// Peripherals (UART, USB) are unaffected: clk_peri stays on pll_usb (48 MHz).
// QMI flash clock stays within spec: SCK = 250 / 2 = 125 MHz (< 133 MHz max).

#include "dvi_output.h"

#include "hardware/clocks.h"
#include "hardware/pll.h"
#include "hardware/vreg.h"
#include "pico/stdlib.h"

void dvi_init_clock(void) {
    // Raise VREG voltage for stable operation at 250 MHz.
    vreg_set_voltage(VREG_VOLTAGE_1_15);
    sleep_ms(10);

    // Reconfigure PLL: 12 MHz * 125 = 1500 MHz VCO, / 6 / 1 = 250 MHz.
    set_sys_clock_pll(1500000000, 6, 1);

    // clk_hstx = sys_clk / 2 = 125 MHz -> pixel clock = 25 MHz.
    clock_configure(clk_hstx, 0,
                    CLOCKS_CLK_HSTX_CTRL_AUXSRC_VALUE_CLK_SYS,
                    250000000, 125000000);
}
