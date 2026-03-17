#ifndef DVI_OUTPUT_H
#define DVI_OUTPUT_H

#include "dvi.h"

// Initialize system clock for DVI 720p output (372 MHz).
//
// Must be called before psram_init() and stdio_init_all().
// Raises VREG to 1.30 V, increases flash QMI divider, reconfigures PLL,
// and sets clk_hstx = sys_clk (372 MHz).
void dvi_init_clock(void);

// Initialize HSTX, DMA, IRQ and start DVI output.
// Must be called after dvi_init_clock() and psram_init().
void dvi_start(void);

// DWT cycle counts for the IRQ handler (prepare_scanline_dma).
// Useful for verifying the handler finishes well within one scanline period.
extern volatile uint32_t dvi_irq_max_cycles;
extern volatile uint32_t dvi_irq_last_cycles;

// Diagnostic: return current HSTX CSR register value.
uint32_t dvi_get_hstx_csr(void);

// Diagnostic: return hsync_cmd[0] to detect command table corruption.
uint32_t dvi_get_hsync_cmd0(void);

// Diagnostic: return HSTX FIFO STAT register.
// Bits [7:0] = LEVEL, bit [8] = FULL, bit [9] = EMPTY, bit [10] = WOF (write-when-full, sticky).
uint32_t dvi_get_fifo_stat(void);

#endif
