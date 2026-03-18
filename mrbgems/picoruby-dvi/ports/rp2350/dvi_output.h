#ifndef DVI_OUTPUT_H
#define DVI_OUTPUT_H

#include "dvi.h"

// Initialize system clock for DVI 640x480 output.
//
// Configures clk_hstx = clk_sys.  No overclocking or VREG changes needed.
void dvi_init_clock(void);

// Initialize HSTX, DMA, IRQ and start DVI output in pixel mode.
// Must be called after dvi_init_clock() and psram_init().
void dvi_start(void);

// Initialize HSTX, DMA, IRQ and start DVI output in the specified mode.
// For DVI_MODE_TEXT, call dvi_text_set_font() before this function.
// Must be called after dvi_init_clock() and psram_init().
void dvi_start_mode(dvi_mode_t mode);

// DWT cycle counts for the IRQ handler (prepare_scanline_dma).
// Useful for verifying the handler finishes well within one scanline period.
extern volatile uint32_t dvi_irq_max_cycles;
extern volatile uint32_t dvi_irq_last_cycles;

// DWT cycle counts for text mode scanline rendering.
extern volatile uint32_t dvi_render_max_cycles;
extern volatile uint32_t dvi_render_last_cycles;

// Diagnostic: return current HSTX CSR register value.
uint32_t dvi_get_hstx_csr(void);

// Diagnostic: return hsync_cmd[0] to detect command table corruption.
uint32_t dvi_get_hsync_cmd0(void);

// Diagnostic: number of times the HSTX FIFO was empty at IRQ entry.
// Non-zero means DVI signal glitches occurred.
uint32_t dvi_get_fifo_empty_count(void);

// Diagnostic: return HSTX FIFO STAT register.
// Bits [7:0] = LEVEL, bit [8] = FULL, bit [9] = EMPTY, bit [10] = WOF (write-when-full, sticky).
uint32_t dvi_get_fifo_stat(void);

// Diagnostic: read and clear SRAM9 (SCRATCH_Y) bus performance counters.
void dvi_read_bus_counters(uint32_t *contested, uint32_t *access);

// FIFO underflow diagnostics
#define DVI_FIFO_EMPTY_LOG_SIZE 8
extern volatile uint32_t dvi_fifo_empty_log[DVI_FIFO_EMPTY_LOG_SIZE];
extern volatile uint32_t dvi_fifo_empty_log_idx;
extern volatile uint32_t dvi_fifo_min_level;

#endif
