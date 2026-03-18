/*
 * Harucom OS -- PicoRuby firmware for Harucom Board
 *
 * Core assignment:
 *   Core 0 -- mruby VM, stdio, timers (needs default alarm pool on core 0)
 *   Core 1 -- DVI output via HSTX + DMA (BASEPRI-isolated, SRAM-only)
 *
 * The DVI DMA IRQ runs on core 1 with BASEPRI blocking all other interrupts.
 * This prevents flash-resident IRQ handlers from running on the DVI core,
 * which would stall on QMI bus contention with PSRAM and cause HSTX FIFO
 * underflow.  Core 0 is free to access flash and PSRAM without restriction.
 *
 * Memory layout for DVI stability:
 *   Core 0 stack:  BSS (main SRAM), 32 KB -- enough for mruby compiler
 *   Framebuffer:   main SRAM, 75 KB (320x240 RGB332)
 *   DMA cmd bufs:  SCRATCH_Y
 *   IRQ handler:   SCRATCH_X (code) -- no I/D bus contention with SCRATCH_Y
 *   DMA reads pixel data directly from framebuf (main SRAM) with bus priority.
 */

#include <stdio.h>
#include <string.h>

#include "dvi_output.h"
#include "hardware/gpio.h"
#include "hardware/timer.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"
#include "picoruby.h"
#include "psram.h"

static const char ruby_code[] =
    "def fill_rect(x, y, w, h, color)\n"
    "  iy = 0\n"
    "  while iy < h\n"
    "    ix = 0\n"
    "    while ix < w\n"
    "      DVI.set_pixel(x + ix, y + iy, color)\n"
    "      ix = ix + 1\n"
    "    end\n"
    "    iy = iy + 1\n"
    "  end\n"
    "end\n"
    "\n"
    "def draw_ball(x, y, r, color)\n"
    "  iy = 0 - r\n"
    "  while iy <= r\n"
    "    ix = 0 - r\n"
    "    while ix <= r\n"
    "      if ix * ix + iy * iy <= r * r\n"
    "        DVI.set_pixel(x + ix, y + iy, color)\n"
    "      end\n"
    "      ix = ix + 1\n"
    "    end\n"
    "    iy = iy + 1\n"
    "  end\n"
    "end\n"
    "\n"
    "def clamp(v, lo, hi)\n"
    "  if v < lo\n"
    "    lo\n"
    "  elsif v > hi\n"
    "    hi\n"
    "  else\n"
    "    v\n"
    "  end\n"
    "end\n"
    "\n"
    "balls = [\n"
    "  [40, 30, 2, 1, 10, 0xe0],\n"
    "  [160, 120, -3, 2, 8, 0x1c],\n"
    "  [250, 80, 1, -2, 12, 0x03],\n"
    "  [100, 200, -2, -1, 6, 0xff],\n"
    "  [200, 50, 3, 3, 9, 0xe3],\n"
    "]\n"
    "\n"
    "loop do\n"
    "  i = 0\n"
    "  while i < balls.length\n"
    "    b = balls[i]\n"
    "    draw_ball(b[0], b[1], b[4], 0x00)\n"
    "    b[0] = b[0] + b[2]\n"
    "    b[1] = b[1] + b[3]\n"
    "    if b[0] - b[4] <= 0 || b[0] + b[4] >= 319\n"
    "      b[2] = 0 - b[2]\n"
    "      b[0] = clamp(b[0], b[4], 319 - b[4])\n"
    "    end\n"
    "    if b[1] - b[4] <= 0 || b[1] + b[4] >= 239\n"
    "      b[3] = 0 - b[3]\n"
    "      b[1] = clamp(b[1], b[4], 239 - b[4])\n"
    "    end\n"
    "    draw_ball(b[0], b[1], b[4], b[5])\n"
    "    i = i + 1\n"
    "  end\n"
    "  DVI.wait_vsync\n"
    "end\n";

// Draw a red/blue checkerboard (40x60 pixel blocks) on the 320x240 framebuffer.
// RGB332: bits 7-5 = R (0-7), bits 4-2 = G (0-7), bits 1-0 = B (0-3)
#define CHECKER_W 40 // block width  (320 / 8 blocks)
#define CHECKER_H 60 // block height (240 / 4 blocks)
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

/* BSS stack for Core 0.
 * The default stack in SCRATCH_Y is only 2 KB (PICO_STACK_SIZE=0x800).
 * The mruby compiler (mrc_load_string_cxt) needs more for complex scripts.
 * BSS stack is in main SRAM.  DMA pixel reads have bus priority set high,
 * so Core 0's SRAM access does not delay them. */
#define BSS_STACK_SIZE (32 * 1024)
static uint8_t bss_stack[BSS_STACK_SIZE] __attribute__((aligned(8)));

/*
 * core1_dvi_entry: DVI output runs on core 1.
 *
 * After dvi_start(), core 1 must never execute flash-resident code.  The QMI
 * bus is shared between flash (CS0) and PSRAM (CS1); heavy PSRAM access from
 * core 0's mruby VM saturates QMI, stalling any flash fetch on core 1.
 * BASEPRI prevents flash-resident ISRs from running on the DVI core.
 *
 * BASEPRI blocks all interrupts with priority >= 0x20.  DMA_IRQ_1 is at
 * priority 0x00 and passes through.
 */
static void core1_dvi_entry(void) {
  dvi_start();

  __asm volatile("msr basepri, %0" ::"r"(0x20u) : "memory");
  while (1) {
    __asm volatile("wfi" ::: "memory");
  }
}

/* Periodic DVI diagnostic output (called from timer IRQ on core 0) */
static bool dvi_diagnostic_callback(struct repeating_timer *t) {
  (void)t;
  printf("DVI: frames=%u fifo_empty=%u irq_max=%u irq_last=%u\n",
         dvi_get_frame_count(), dvi_get_fifo_empty_count(), dvi_irq_max_cycles,
         dvi_irq_last_cycles);
  return true;
}

/*
 * run_mruby: compile and run a Ruby script on the mruby task scheduler.
 *
 * The alarm IRQ registered by mrb_hal_task_init fires on the calling core
 * (core 0), so mrb_task_disable_irq (cpsid i) correctly serialises the
 * alarm handler vs the task scheduler without touching core 1's DVI IRQ.
 */
static void run_mruby(void) {
  printf("Starting PicoRuby...\n");
  mrb_state *mrb = mrb_open_with_custom_alloc(heap_pool_g, heap_size_g);
  if (!mrb) {
    printf("mrb_open failed\n");
    return;
  }
  global_mrb = mrb;

  mrc_ccontext *cc = mrc_ccontext_new(mrb);
  const uint8_t *src = (const uint8_t *)ruby_code;
  mrc_irep *irep = mrc_load_string_cxt(cc, &src, strlen(ruby_code));
  if (!irep) {
    printf("compile failed\n");
    return;
  }
  printf("compile OK\n");

  mrb_value name = mrb_str_new_cstr(mrb, "blink");
  mrb_value task = mrc_create_task(cc, irep, name, mrb_nil_value(),
                                   mrb_obj_value(mrb->top_self));
  if (mrb_nil_p(task)) {
    printf("create_task failed\n");
    return;
  }

  printf("running task scheduler\n");
  mrb_task_run(mrb);
}

static void harucom_main(void);

int main(void) {
  /* Switch Core 0 stack from SCRATCH_Y (2 KB) to BSS (32 KB).
   * Must happen before any deep calls (mruby compiler needs >2 KB).
   * After this, the SCRATCH_Y stack region is unused. */
  __asm volatile("msr msp, %0" ::"r"((uint32_t)(bss_stack + BSS_STACK_SIZE))
                 : "memory");
  harucom_main();
  return 0;
}

static void harucom_main(void) {
  /* Configure clk_hstx for DVI 640x480 */
  dvi_init_clock();

  stdio_init_all();
  sleep_ms(2000); /* Wait for USB enumeration */

  printf("Harucom OS %s (built %s)\n", HARUCOM_VERSION, HARUCOM_BUILD_DATE);

  /* Initialize PSRAM */
  size_t heap_size;
  void *heap_pool = psram_init(&heap_size);
  if (!heap_pool) {
    printf("PSRAM init failed\n");
    return;
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

  /* Start periodic DVI diagnostics (every 1 second) */
  static struct repeating_timer diag_timer;
  add_repeating_timer_ms(1000, dvi_diagnostic_callback, NULL, &diag_timer);

  /* Run mruby on core 0 (has default alarm pool, stdio, timers) */
  run_mruby();

  /* run_mruby returns only on error */
  for (;;)
    __asm volatile("wfe");
}
