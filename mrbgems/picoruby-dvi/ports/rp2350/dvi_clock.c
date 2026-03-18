// DVI clock initialization for 640x480 output.
//
// Overclocks sys_clk to 375 MHz and sets clk_hstx = sys_clk / 3 = 125 MHz.
// The HSTX serializer uses CLKDIV=5, so pixel clock = 125 / 5 = 25 MHz.
//
// At 375 MHz, each scanline provides 12,000 CPU cycles for text mode
// rendering, giving comfortable margin for the ~2,200 cycle render loop.
//
// Peripherals (UART, USB) are unaffected: clk_peri stays on pll_usb (48 MHz).
// QMI flash divider increased to 4: SCK = 375 / 4 = 93.75 MHz (< 133 MHz max).
//
// Must be called before any flash-dependent initialization (stdio, etc.)
// because it changes QMI timing. Runs from SRAM to avoid flash access during
// the QMI reconfiguration.

#include "dvi_output.h"

#include "hardware/clocks.h"
#include "hardware/pll.h"
#include "hardware/structs/qmi.h"
#include "hardware/vreg.h"
#include "pico/stdlib.h"

void __not_in_flash_func(dvi_init_clock)(void) {
    // 1. Increase QMI flash clock divider BEFORE overclocking.
    //    Boot stage 2 sets CLKDIV=2 (SCK = sys_clk/2 = 75 MHz at 150 MHz).
    //    At 375 MHz with CLKDIV=2, SCK=187.5 MHz exceeds flash max (~133 MHz).
    //    CLKDIV=4: SCK = 375/4 = 93.75 MHz (within spec).
    hw_write_masked(&qmi_hw->m[0].timing,
                    4u << QMI_M0_TIMING_CLKDIV_LSB,
                    QMI_M0_TIMING_CLKDIV_BITS);
    // Dummy read via non-cached window to flush the QMI bus.
    (void)*(volatile uint32_t *)XIP_NOCACHE_NOALLOC_BASE;
    __asm volatile("dsb" ::: "memory");

    // 2. Raise VREG voltage for stable operation at 375 MHz.
    vreg_set_voltage(VREG_VOLTAGE_1_30);
    sleep_ms(10);

    // 3. Reconfigure PLL: 12 MHz * 125 = 1500 MHz VCO, / 4 / 1 = 375 MHz.
    set_sys_clock_pll(1500000000, 4, 1);

    // 4. clk_hstx = sys_clk / 3 = 125 MHz -> pixel clock = 25 MHz.
    clock_configure(clk_hstx, 0,
                    CLOCKS_CLK_HSTX_CTRL_AUXSRC_VALUE_CLK_SYS,
                    375000000, 125000000);
}
