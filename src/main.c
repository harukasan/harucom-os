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
 *   Text VRAM:     main SRAM, ~31 KB (106x37 cells, double-buffered)
 *   DMA cmd bufs:  SCRATCH_Y
 *   Line buffers:  SCRATCH_Y (double-buffered 640B each)
 *   IRQ handler:   SCRATCH_X (code) -- no I/D bus contention with SCRATCH_Y
 */

#include <stdio.h>
#include <string.h>

#include "init_rootfs.h"
#include "dvi_output.h"
#include "hardware/gpio.h"
#include "hardware/timer.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"
#include "picoruby.h"
#include "psram.h"
#include "usb_host.h"
#include <mruby/array.h>
#include <mruby/string.h>

#include "font_mplus_f12b.h"
#include "font_mplus_f12r.h"
#include "font_mplus_j12_combined.h"

/* Minimal Ruby bootstrap: mount filesystem, set load path, load system.rb. */
// clang-format off
static const char ruby_bootstrap[] =
    "fat = FAT.new(:flash, label: \"HARUCOM\")\n"
    "retry_count = 0\n"
    "begin\n"
    "  VFS.mount(fat, \"/\")\n"
    "rescue => e\n"
    "  fat._mkfs(\"flash:\")\n"
    "  retry_count = retry_count + 1\n"
    "  retry if retry_count == 1\n"
    "  raise e\n"
    "end\n"
    "$LOAD_PATH = [\"/lib\"]\n"
    "\n"
    "load \"/system.rb\"\n";

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
 * Core 1 vector table in SRAM.
 *
 * The default vector table is in flash.  During flash erase/program,
 * XIP is disabled, so any interrupt dispatch on Core 1 would fault
 * when reading the handler address from the vector table.
 *
 * After dvi_start_mode() registers the DMA IRQ handler, we copy the
 * entire vector table to SRAM and point VTOR here.  Combined with
 * PICO_FLASH_ASSUME_CORE1_SAFE=1 and DVI blanking during flash writes,
 * Core 1 never accesses flash.
 *
 * 16 system exceptions + 52 IRQs = 68 entries.
 * VTOR requires 512-byte alignment on Cortex-M33.
 */
#define VTOR_TABLE_ENTRIES (16 + NUM_IRQS)
static uint32_t __attribute__((aligned(512)))
    core1_vector_table[VTOR_TABLE_ENTRIES];

/*
 * core1_dvi_entry: DVI output runs on core 1.
 *
 * After dvi_start_mode(), core 1 must never execute flash-resident code.
 * BASEPRI blocks all interrupts with priority >= 0x20.  DMA_IRQ_1 is at
 * priority 0x00 and passes through.
 *
 * Flash write safety relies on three mechanisms:
 *   1. DVI blanking: flash_disk.c enables blanking before flash ops,
 *      so the DMA IRQ handler outputs blank lines (no .rodata access).
 *   2. VTOR in SRAM: interrupt dispatch reads handler addresses from
 *      SRAM, not flash.
 *   3. __not_in_flash_func: this function (including the WFI loop)
 *      runs from SRAM.
 */
static void __not_in_flash_func(core1_dvi_entry)(void) {
    dvi_start_mode(DVI_MODE_TEXT);

    /* Copy vector table to SRAM after DMA IRQ handler is registered */
    volatile uint32_t *vtor_reg = (volatile uint32_t *)0xE000ED08;
    uint32_t *flash_vtable = (uint32_t *)*vtor_reg;
    for (int i = 0; i < VTOR_TABLE_ENTRIES; i++)
        core1_vector_table[i] = flash_vtable[i];
    *vtor_reg = (uint32_t)core1_vector_table;
    __asm volatile("dsb" ::: "memory");
    __asm volatile("isb" ::: "memory");

    __asm volatile("msr basepri, %0" ::"r"(0x20u) : "memory");
    while (1) {
        __asm volatile("wfi" ::: "memory");
    }
}

#ifdef DVI_DIAGNOSTICS
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
#endif


/*
 * run_mruby: mount filesystem, load /system.rb from flash,
 * then run the mruby task scheduler.
 */
static void run_mruby(void) {
    printf("Starting PicoRuby...\n");
    mrb_state *mrb = mrb_open_with_custom_alloc(heap_pool_g, heap_size_g);
    if (!mrb) {
        printf("mrb_open failed\n");
        return;
    }
    global_mrb = mrb;

    mrb_define_global_const(mrb, "HARUCOM_VERSION",
                            mrb_str_new_cstr(mrb, HARUCOM_VERSION));
    mrb_define_global_const(mrb, "HARUCOM_BUILD_DATE",
                            mrb_str_new_cstr(mrb, HARUCOM_BUILD_DATE));

    mrc_ccontext *cc = mrc_ccontext_new(mrb);
    const uint8_t *src = (const uint8_t *)ruby_bootstrap;
    mrc_irep *irep = mrc_load_string_cxt(cc, &src, strlen(ruby_bootstrap));
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

    /* Print unhandled exception if the task exited with an error */
    if (mrb->exc) {
        mrb_value exc = mrb_obj_value(mrb->exc);
        mrb_value msg = mrb_funcall(mrb, exc, "inspect", 0);
        if (mrb_string_p(msg)) {
            printf("Exception: %s\n", RSTRING_PTR(msg));
        }
        mrb_value bt = mrb_funcall(mrb, exc, "backtrace", 0);
        if (mrb_array_p(bt)) {
            for (mrb_int i = 0; i < RARRAY_LEN(bt); i++) {
                mrb_value line = mrb_ary_ref(mrb, bt, i);
                if (mrb_string_p(line))
                    printf("  %s\n", RSTRING_PTR(line));
            }
        }
    } else {
        printf("task scheduler exited normally\n");
    }
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
    printf("PSRAM: %u bytes at %p\n", (unsigned)heap_size, heap_pool);

    /* Reserve the first 307,200 bytes of PSRAM for 640x480 graphics back buffer.
     * At 320x240, the SRAM framebuf is used for double buffering instead. */
    size_t fb_size = DVI_GRAPHICS_MAX_WIDTH * DVI_GRAPHICS_MAX_HEIGHT;
    dvi_graphics_set_back_buffer((uint8_t *)heap_pool);
    heap_pool_g = (void *)((uintptr_t)heap_pool + fb_size);
    heap_size_g = heap_size - fb_size;
    printf("Graphics back buffer: %u bytes at %p\n", (unsigned)fb_size, heap_pool);
    printf("mruby heap: %u bytes at %p\n", (unsigned)heap_size_g, heap_pool_g);

    /* Initialize root filesystem before launching DVI on core 1.
     * Flash programming requires exclusive XIP access, which conflicts
     * with DVI scanline rendering on core 1. */
    init_rootfs();

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

#ifdef DVI_DIAGNOSTICS
    /* Start periodic DVI diagnostics (every 1 second) */
    static struct repeating_timer diag_timer;
    add_repeating_timer_ms(1000, dvi_diagnostic_callback, NULL, &diag_timer);
#endif

    /* Initialize USB host (PIO-USB on RHPORT 1) */
    usb_host_init();

    /* Run mruby on core 0 (has default alarm pool, stdio, timers) */
    run_mruby();

    /* run_mruby returns only on error */
    for (;;)
        __asm volatile("wfe");
}
