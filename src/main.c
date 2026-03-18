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

#include "fonts/font_mplus_f12r.h"
#include "fonts/font_mplus_f12b.h"
#include "fonts/font_mplus_j12_combined.h"

static const char ruby_code[] =
    "count = 0\n"
    "loop do\n"
    "  DVI.text_put_string(0, 20, \"frame: #{count}    \", 0xF0)\n"
    "  DVI.text_put_string(0, 21, \"Hello from Ruby!\", 0xA0)\n"
    "  DVI.text_put_string(0, 22, \"Testing flash contention...\", 0xE0)\n"
    "  col = count % 106\n"
    "  row = 24 + (count / 106) % 10\n"
    "  DVI.text_put_char(col, row, 0x41 + count % 26, 0xB0)\n"
    "  count = count + 1\n"
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
static bool dvi_diagnostic_callback(struct repeating_timer *t) {
    (void)t;
    printf("DVI: frames=%u fifo_empty=%u irq_max=%u render_max=%u render_last=%u\n",
           dvi_get_frame_count(), dvi_get_fifo_empty_count(),
           dvi_irq_max_cycles, dvi_render_max_cycles, dvi_render_last_cycles);
    return true;
}

/* Set up text mode demo content */
static void setup_text_demo(void) {
    // attr = (fg << 4) | bg
    uint8_t attr_white  = 0xF0;  // white on black
    uint8_t attr_green  = 0xA0;  // light green on black
    uint8_t attr_cyan   = 0xB0;  // light cyan on black
    uint8_t attr_yellow = 0xE0;  // yellow on black

    dvi_text_clear(attr_white);

    // Title
    dvi_text_put_string_bold(0, 0, "Harucom OS Text Mode", attr_yellow);
    dvi_text_put_string(0, 1, "640x480 native resolution, 106 columns x 36 rows", attr_green);
    dvi_text_put_string(0, 2, "12px M+ font (6px half-width + 12px full-width)", attr_green);

    // ASCII table
    dvi_text_put_string(0, 4, "ASCII characters:", attr_cyan);
    for (int i = 0x20; i < 0x7F; i++) {
        int col = (i - 0x20) % 53;
        int row = 5 + (i - 0x20) / 53;
        dvi_text_put_char(col, row, (char)i, attr_white);
    }

    // Color palette demo
    dvi_text_put_string(0, 9, "Color palette:", attr_cyan);
    for (int fg = 0; fg < 16; fg++) {
        uint8_t attr = (fg << 4) | 0x00;  // fg on black
        char label[4];
        label[0] = "0123456789ABCDEF"[fg];
        label[1] = ' ';
        label[2] = '\0';
        dvi_text_put_string(fg * 3, 10, label, attr);
    }

    // Bold text test
    dvi_text_put_string(0, 12, "Bold text:", attr_cyan);
    dvi_text_put_string_bold(0, 13, "The quick brown fox jumps over the lazy dog.", attr_white);
    dvi_text_put_string(0, 14, "The quick brown fox jumps over the lazy dog.", attr_white);
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

    /* Fill text VRAM after DVI is running (dvi_start_mode clears VRAM). */
    setup_text_demo();
    printf("DVI frame_count after 500ms: %u (expect ~30)\n",
           dvi_get_frame_count());
    printf("DVI IRQ max cycles: %u, render max: %u\n",
           dvi_irq_max_cycles, dvi_render_max_cycles);

    /* Start periodic DVI diagnostics (every 1 second) */
    static struct repeating_timer diag_timer;
    add_repeating_timer_ms(1000, dvi_diagnostic_callback, NULL, &diag_timer);

    /* Run mruby on core 0 (has default alarm pool, stdio, timers) */
    run_mruby();

    /* run_mruby returns only on error */
    for (;;)
        __asm volatile("wfe");
}
