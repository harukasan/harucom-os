#ifndef DVI_OUTPUT_H
#define DVI_OUTPUT_H

#include <stdint.h>

// Initialize system clock for DVI 720p output (372 MHz).
//
// Must be called before psram_init() and stdio_init_all().
// Raises VREG to 1.30 V, increases flash QMI divider, reconfigures PLL,
// and sets clk_hstx = sys_clk (372 MHz).
void dvi_init_clock(void);

// Framebuffer dimensions (640x360 RGB332, 2x scaled to 1280x720 output).
#define DVI_FRAME_WIDTH  640
#define DVI_FRAME_HEIGHT 360

// Initialize HSTX, DMA, IRQ and start DVI output.
// Must be called after dvi_init_clock() and psram_init().
void dvi_start(void);

// Return a pointer to the 640x360 RGB332 framebuffer.
uint8_t *dvi_get_framebuffer(void);

// Return the frame counter (incremented each vsync).
uint32_t dvi_get_frame_count(void);

// Wait for the next vsync (blocks with WFI).
void dvi_wait_vsync(void);

// DWT cycle counts for the IRQ handler (prepare_scanline_dma).
// Useful for verifying the handler finishes well within one scanline period.
extern volatile uint32_t dvi_irq_max_cycles;
extern volatile uint32_t dvi_irq_last_cycles;

#endif
