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
 *   Text VRAM:     main SRAM, ~15 KB (106x37 cells)
 *   DMA cmd bufs:  SCRATCH_Y
 *   Line buffers:  SCRATCH_Y (double-buffered 640B each)
 *   IRQ handler:   SCRATCH_X (code) -- no I/D bus contention with SCRATCH_Y
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
#include "usb_host.h"

#include "fonts/font_mplus_f12b.h"
#include "fonts/font_mplus_f12r.h"
#include "fonts/font_mplus_j12_combined.h"

// clang-format off
static const char ruby_code[] =
    "# USB keyboard input demo\n"
    "BLANK = \" \" * 106\n"
    "\n"
    "loop do\n"
    "  USB::Host.task\n"
    "  if USB::Host.keyboard_connected?\n"
    "    keys = USB::Host.keyboard_keycodes\n"
    "    mod = USB::Host.keyboard_modifier\n"
    "    line = \"mod=\" + mod.to_s + \" keys=\" + keys.to_s\n"
    "    DVI::Text.put_string(0, 0, BLANK, 0xF0)\n"
    "    DVI::Text.put_string(0, 0, line, 0xF0)\n"
    "  else\n"
    "    DVI::Text.put_string(0, 0, BLANK, 0xF0)\n"
    "    DVI::Text.put_string(0, 0, \"No keyboard connected\", 0xF0)\n"
    "  end\n"
    "  DVI.wait_vsync\n"
    "end\n";

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
 * After dvi_start_mode(), core 1 must never execute flash-resident code.
 * BASEPRI blocks all interrupts with priority >= 0x20.  DMA_IRQ_1 is at
 * priority 0x00 and passes through.
 */
static void core1_dvi_entry(void) {
    dvi_start_mode(DVI_MODE_TEXT);

    __asm volatile("msr basepri, %0" ::"r"(0x20u) : "memory");
    while (1) {
        __asm volatile("wfi" ::: "memory");
    }
}

/* Periodic DVI diagnostic output (called from timer IRQ on core 0) */
static uint32_t prev_fifo_empty = 0;
static bool dvi_diagnostic_callback(struct repeating_timer *t) {
    (void)t;
    uint32_t contested, access;
    dvi_read_bus_counters(&contested, &access);
    uint32_t empty = dvi_get_fifo_empty_count();
    // Per-line headroom: H-blanking budget (2240) minus last single-line render
    // Batch headroom: 4-scanline budget (32000) minus last batch render total
    int32_t line_headroom = 2240 - (int32_t)dvi_render_last_cycles;
    int32_t batch_headroom = 32000 - (int32_t)dvi_batch_render_last_cycles;
    printf("DVI: f=%u fe=%u rl=%u bt=%u headroom: line=%d batch=%d",
           dvi_get_frame_count(), empty,
           dvi_render_last_cycles,
           dvi_batch_render_last_cycles,
           line_headroom, batch_headroom);
    // Print FIFO empty log if new events occurred
    if (empty > prev_fifo_empty) {
        printf(" lines=[");
        uint32_t log_count = dvi_fifo_empty_log_idx;
        if (log_count > DVI_FIFO_EMPTY_LOG_SIZE)
            log_count = DVI_FIFO_EMPTY_LOG_SIZE;
        for (uint32_t i = 0; i < log_count; i++)
            printf("%s%u", i ? "," : "", (unsigned)dvi_fifo_empty_log[i]);
        printf("]");
    }
    prev_fifo_empty = empty;
    // Reset diagnostic min/max each interval
    dvi_fifo_min_level = 0xFF;
    dvi_irq_interval_min = 0xFFFFFFFF;
    dvi_irq_interval_max = 0;
    printf("\n");
    return true;
}


/*
 * run_mruby: compile and run a Ruby script on the mruby task scheduler.
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

    mrb_value name = mrb_str_new_cstr(mrb, "main");
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

    /* Set up text mode fonts before launching DVI on core 1.
     * Font data must be configured before dvi_start_mode() because the
     * scanline renderer needs the font to be set. */
    dvi_text_set_font(&font_mplus_f12r);
    dvi_text_set_bold_font(&font_mplus_f12b);
    dvi_text_set_wide_font(&font_mplus_j12_combined);

    /* Launch core 1 for DVI output.
     * dvi_start_mode() configures HSTX + DMA and registers DMA_IRQ_1 on
     * core 1's NVIC, then enters a BASEPRI-masked WFI loop. */
    printf("Launching DVI text mode on core 1...\n");
    multicore_launch_core1_with_stack(core1_dvi_entry, dvi_stack_mem,
                                      sizeof(dvi_stack_mem));

    sleep_ms(500);

    /* Clear text VRAM after DVI is running (dvi_start_mode clears VRAM). */
    dvi_text_clear(0xF0);
    printf("DVI frame_count after 500ms: %u (expect ~30)\n",
           dvi_get_frame_count());
    printf("DVI IRQ max cycles: %u, render max: %u, interval: %u-%u\n",
           dvi_irq_max_cycles, dvi_render_max_cycles,
           dvi_irq_interval_min, dvi_irq_interval_max);

    /* Start periodic DVI diagnostics (every 1 second) */
    static struct repeating_timer diag_timer;
    add_repeating_timer_ms(1000, dvi_diagnostic_callback, NULL, &diag_timer);

    /* Initialize USB host (PIO-USB on RHPORT 1) */
    usb_host_init();

    /* Run mruby on core 0 (has default alarm pool, stdio, timers) */
    run_mruby();

    /* run_mruby returns only on error */
    for (;;)
        __asm volatile("wfe");
}
