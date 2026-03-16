#ifndef DVI_OUTPUT_H
#define DVI_OUTPUT_H

// Initialize system clock for DVI 720p output (372 MHz).
//
// Must be called before psram_init() and stdio_init_all().
// Raises VREG to 1.30 V, increases flash QMI divider, reconfigures PLL,
// and sets clk_hstx = sys_clk (372 MHz).
void dvi_init_clock(void);

#endif
