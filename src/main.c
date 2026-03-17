/*
 * Harucom OS — DVI output test
 */

#include <stdio.h>

#include "pico/stdlib.h"
#include "dvi_output.h"
#include "psram.h"

// Draw a red/blue checkerboard (80x90 pixel blocks) on the 640x360 framebuffer.
// RGB332: bits 7-5 = R (0-7), bits 4-2 = G (0-7), bits 1-0 = B (0-3)
#define CHECKER_W 80  // block width  (640 / 8 blocks)
#define CHECKER_H 90  // block height (360 / 4 blocks)
static void draw_checkerboard(uint8_t *fb) {
    for (int y = 0; y < DVI_FRAME_HEIGHT; y++) {
        int row = y / CHECKER_H;
        for (int x = 0; x < DVI_FRAME_WIDTH; x++) {
            int col = x / CHECKER_W;
            fb[y * DVI_FRAME_WIDTH + x] = ((row + col) & 1) ? 0xe0 : 0x03;
            //                                                  red       blue
        }
    }
}

int main(void) {
  /* Overclock to 372 MHz for DVI 720p */
  dvi_init_clock();

  stdio_init_all();
  sleep_ms(2000); /* Wait for UART to stabilize */

  printf("Harucom OS %s (built %s)\n", HARUCOM_VERSION, HARUCOM_BUILD_DATE);

  /* Initialize PSRAM */
  size_t heap_size;
  void *heap_pool = psram_init(&heap_size);
  if (!heap_pool) {
    printf("PSRAM init failed\n");
    return 1;
  }
  printf("PSRAM heap: %u bytes at %p\n", (unsigned)heap_size, heap_pool);

  /* Start DVI output with checkerboard test pattern */
  draw_checkerboard(dvi_get_framebuffer());
  dvi_start();
  printf("DVI output started\n");

  /* Verify DVI IRQ is running: frame_count should reach ~30 after 500ms */
  sleep_ms(500);
  printf("DVI frame_count after 500ms: %u (expect ~30)\n", dvi_get_frame_count());
  printf("DVI IRQ max cycles: %u, last: %u\n",
         dvi_irq_max_cycles, dvi_irq_last_cycles);

  for (;;) {
    dvi_wait_vsync();
  }

  return 0;
}
