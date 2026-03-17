/*
 * Harucom OS — PicoRuby firmware for Harucom Board
 *
 * Core assignment:
 *   Core 0 — mruby VM, stdio, timers (needs default alarm pool on core 0)
 *   Core 1 — DVI output via HSTX + DMA (BASEPRI-isolated, SRAM-only)
 *
 * The DVI DMA IRQ runs on core 1 with BASEPRI blocking all other interrupts.
 * This prevents flash-resident IRQ handlers from running on the DVI core,
 * which would stall on QMI bus contention with PSRAM and cause HSTX FIFO
 * underflow.  Core 0 is free to access flash and PSRAM without restriction.
 */

#include <stdio.h>
#include <string.h>

#include "dvi_output.h"
#include "hardware/gpio.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"
#include "picoruby.h"
#include "psram.h"

static const char ruby_code[] = "i = 0\n"
                                "loop do\n"
                                "  i = i + 1\n"
                                "  sleep_ms(100)\n"
                                "end\n";

// Draw a red/blue checkerboard (80x90 pixel blocks) on the 640x360 framebuffer.
// RGB332: bits 7-5 = R (0-7), bits 4-2 = G (0-7), bits 1-0 = B (0-3)
#define CHECKER_W 80 // block width  (640 / 8 blocks)
#define CHECKER_H 90 // block height (360 / 4 blocks)
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

mrb_state *global_mrb = NULL;

/* PSRAM heap passed to mruby */
static void *heap_pool_g;
static size_t heap_size_g;

/* Core 1 stack for DVI: only needs enough for dvi_start() init and DMA IRQ.
 * 4 KB is sufficient (dma_irq_handler itself is in SCRATCH_X). */
#define DVI_STACK_SIZE (4 * 1024)
static uint32_t dvi_stack_mem[DVI_STACK_SIZE / sizeof(uint32_t)];

/*
 * core1_dvi_entry: DVI output runs on core 1.
 *
 * After dvi_start(), core 1 must never execute flash-resident code.  The QMI
 * bus is shared between flash (CS0) and PSRAM (CS1); heavy PSRAM access from
 * core 0's mruby VM saturates QMI, stalling any flash fetch on core 1.  If
 * the stall delays DMA_IRQ_1 entry beyond the HSTX FIFO buffer (~215 ns at
 * 720p), the FIFO underflows and the DVI signal is lost.
 *
 * BASEPRI blocks all interrupts with priority >= 0x20.  DMA_IRQ_1 is at
 * priority 0x00 and passes through.
 */
static void core1_dvi_entry(void) {
  dvi_start();

  __asm volatile("msr basepri, %0" :: "r"(0x20u) : "memory");
  while (1) {
    __asm volatile("wfi" ::: "memory");
  }
}

int main(void) {
  /* Overclock to 372 MHz for DVI 720p */
  dvi_init_clock();

  stdio_init_all();
  sleep_ms(2000); /* Wait for USB enumeration */

  printf("Harucom OS %s (built %s)\n", HARUCOM_VERSION, HARUCOM_BUILD_DATE);

  /* Initialize PSRAM */
  size_t heap_size;
  void *heap_pool = psram_init(&heap_size);
  if (!heap_pool) {
    printf("PSRAM init failed\n");
    return 1;
  }
  printf("PSRAM heap: %u bytes at %p\n", (unsigned)heap_size, heap_pool);
  heap_pool_g = heap_pool;
  heap_size_g = heap_size;

  /* Fill framebuffer before launching DVI */
  draw_checkerboard(dvi_get_framebuffer());

  /* Launch core 1 for DVI output.
   * dvi_start() configures HSTX + DMA and registers DMA_IRQ_1 on core 1's
   * NVIC, then enters a BASEPRI-masked WFI loop. */
  printf("Launching DVI on core 1...\n");
  multicore_launch_core1_with_stack(core1_dvi_entry, dvi_stack_mem,
                                    sizeof(dvi_stack_mem));

  sleep_ms(500);
  printf("DVI frame_count after 500ms: %u (expect ~30)\n",
         dvi_get_frame_count());
  printf("DVI IRQ max cycles: %u, last: %u\n", dvi_irq_max_cycles,
         dvi_irq_last_cycles);

  /* --- Animation + PSRAM stress test on core 0 --- */
  uint8_t *fb = dvi_get_framebuffer();
  uint8_t *psram = (uint8_t *)heap_pool;
  uint32_t frame = 0;

  dvi_irq_max_cycles = 0;
  printf("Starting animation + PSRAM stress test\n");
  while (1) {
    /* Scroll checkerboard horizontally */
    int off = frame % (CHECKER_W * 2);
    for (int y = 0; y < DVI_FRAME_HEIGHT; y++) {
      int row = y / CHECKER_H;
      for (int x = 0; x < DVI_FRAME_WIDTH; x++) {
        int col = (x + off) / CHECKER_W;
        fb[y * DVI_FRAME_WIDTH + x] = ((row + col) & 1) ? 0xe0 : 0x03;
      }
    }

    /* Stress PSRAM: write and read back 64 KB per frame */
    for (int i = 0; i < 65536; i++)
      psram[i] = (uint8_t)(frame + i);
    volatile uint8_t sum = 0;
    for (int i = 0; i < 65536; i++)
      sum += psram[i];
    (void)sum;

    dvi_wait_vsync();

    if (++frame % 300 == 0)
      printf("frame=%u irq_max=%u\n", frame, dvi_irq_max_cycles);
  }
}
