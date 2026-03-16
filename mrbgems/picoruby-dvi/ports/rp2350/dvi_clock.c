// DVI clock initialization for 720p output (372 MHz).
//
// Based on the configure_clock() function from the hakodate-project
// dvi_text_console sample. See doc/dvi.md for design rationale.

#include "dvi_output.h"

#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/structs/qmi.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"
#include <pico/platform/common.h>

void __not_in_flash_func(dvi_init_clock)(void) {
    // 1. Increase QMI flash clock divider BEFORE overclocking.
    //    Boot stage 2 sets CLKDIV=2 (SCK = sys_clk/2 = 62.5 MHz).
    //    At 372 MHz with CLKDIV=2, SCK=186 MHz exceeds flash max (~133 MHz).
    //    CLKDIV=4: SCK = 372/4 = 93 MHz (within spec).
    hw_write_masked(&qmi_hw->m[0].timing,
                    4u << QMI_M0_TIMING_CLKDIV_LSB,
                    QMI_M0_TIMING_CLKDIV_BITS);
    // Dummy read via non-cached window to ensure the QMI bus access actually
    // occurs (XIP_BASE would hit cache and not reach QMI hardware).
    (void)*(volatile uint32_t *)XIP_NOCACHE_NOALLOC_BASE;
    __dsb();

    // 2. Raise VREG voltage for stable operation at 372 MHz.
    vreg_set_voltage(VREG_VOLTAGE_1_30);
    sleep_ms(10);

    // 3. Reconfigure PLL: 12 MHz × 93 = 1116 MHz VCO, /3/1 = 372 MHz.
    //    set_sys_clock_pll() internally switches CLK_SYS to PLL_USB (48 MHz)
    //    before reconfiguring PLL_SYS, then switches back.
    set_sys_clock_pll(1116000000, 3, 1);

    // 4. Set clk_hstx to sys_clk / 1 (720p: 372 MHz → pixel clock 74.4 MHz).
    uint32_t sys_freq = 372000000;
    clock_configure(clk_hstx, 0,
                    CLOCKS_CLK_HSTX_CTRL_AUXSRC_VALUE_CLK_SYS,
                    sys_freq, sys_freq);
}
