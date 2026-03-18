// DVI clock initialization for 640x480 output.
//
// Configures clk_hstx = clk_sys.  The HSTX serializer uses CLKDIV=5 and
// N_SHIFTS=5, so the pixel clock is sys_clk / 5.  On RP2350 with the
// default 150 MHz sys_clk this gives 30.0 MHz (+19% from 25.175 MHz
// standard), which is within the tolerance of most DVI/HDMI monitors
// for 640x480.  To get an exact 25 MHz pixel clock, reconfigure PLL_SYS
// to 125 MHz here.

#include "dvi_output.h"

#include "hardware/clocks.h"
#include "pico/stdlib.h"

void dvi_init_clock(void) {
    uint32_t sys_freq = clock_get_hz(clk_sys);
    clock_configure(clk_hstx, 0,
                    CLOCKS_CLK_HSTX_CTRL_AUXSRC_VALUE_CLK_SYS,
                    sys_freq, sys_freq);
}
