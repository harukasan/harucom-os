// Copyright (c) 2026 Shunsuke Michii
//
// DVI output driver using CMD->DATA DMA architecture with HSTX TMDS encoder.
// Outputs 1280x720 @ 60Hz DVI from a 640x360 RGB332 framebuffer (2x scaling).
//
// Based on dvi_out_hstx_encoder from pico-examples:
//   Copyright (c) 2024 Raspberry Pi (Trading) Ltd.
//   https://github.com/raspberrypi/pico-examples/tree/master/hstx/dvi_out_hstx_encoder
//
// DMA architecture inspired by PicoLibSDK disphstx:
//   Copyright (c) 2024 Miroslav Nemecek
//   https://github.com/Panda381/PicoLibSDK

#include "dvi_output.h"

#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/structs/bus_ctrl.h"
#include "hardware/structs/hstx_ctrl.h"
#include "hardware/structs/hstx_fifo.h"
#include "hardware/sync.h"

// ----------------------------------------------------------------------------
// DVI constants

// TMDS control symbols encode sync signals as 10-bit patterns.
// On lane 0 (blue), the two data bits carry HSYNC (D0) and VSYNC (D1).
// Lanes 1 and 2 always transmit CTRL_00 during sync periods.
#define TMDS_CTRL_00 0x354u  // D1=0, D0=0
#define TMDS_CTRL_01 0x0abu  // D1=0, D0=1
#define TMDS_CTRL_10 0x154u  // D1=1, D0=0
#define TMDS_CTRL_11 0x2abu  // D1=1, D0=1

// Combined 30-bit sync words for all 3 TMDS lanes (10 bits each).
#define SYNC_V0_H0 (TMDS_CTRL_00 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))
#define SYNC_V0_H1 (TMDS_CTRL_01 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))
#define SYNC_V1_H0 (TMDS_CTRL_10 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))
#define SYNC_V1_H1 (TMDS_CTRL_11 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))

// 1280x720 @ 60Hz uses positive sync polarity: 1 = asserted, 0 = inactive.
// SYNC_HSYNC_OFF/ON refer to the HSYNC signal state.
// SYNC_VSYNC_OFF/ON are used during the VSYNC period (VSYNC=1).
#define SYNC_HSYNC_OFF SYNC_V0_H0  // neither sync active
#define SYNC_HSYNC_ON  SYNC_V0_H1  // HSYNC active
#define SYNC_VSYNC_OFF SYNC_V1_H0  // VSYNC active, HSYNC inactive
#define SYNC_VSYNC_ON  SYNC_V1_H1  // VSYNC active, HSYNC active

// 1280x720 @ 60Hz timing (pixel clock = 74.25 MHz)
// H total = 110 + 40 + 220 + 1280 = 1650 pixels
// V total = 5 + 5 + 20 + 720 = 750 lines
#define MODE_H_FRONT_PORCH    110
#define MODE_H_SYNC_WIDTH     40
#define MODE_H_BACK_PORCH     220
#define MODE_H_ACTIVE_PIXELS  640   // render width (2x HSTX scaling -> 1280 output)
#define MODE_H_OUTPUT_PIXELS  1280  // actual output pixel count for TMDS/RAW commands

#define MODE_V_FRONT_PORCH    5
#define MODE_V_SYNC_WIDTH     5
#define MODE_V_BACK_PORCH     20
#define MODE_V_ACTIVE_LINES   720
#define MODE_V_TOTAL_LINES    (MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH + \
                               MODE_V_SYNC_WIDTH + MODE_V_BACK_PORCH)

// HSTX command expander opcodes (upper 4 bits of command word)
#define HSTX_CMD_RAW_REPEAT  (0x1u << 12)  // Repeat raw data N times
#define HSTX_CMD_TMDS        (0x2u << 12)  // TMDS-encode N pixels from FIFO

#define GPIO_FUNC_HSTX 0

// ----------------------------------------------------------------------------
// HSTX command templates
//
// These are shared HSTX command sequences referenced by DMA transfers.
// In the CMD->DATA architecture, each DMA descriptor specifies which template
// to send and how many words it contains.

// HSYNC prefix for active lines (7 words):
// front porch, sync pulse, back porch, then start TMDS pixel encoding.
// Pixel data follows as a separate DMA transfer.
static uint32_t hsync_cmd[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_HSYNC_OFF,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_HSYNC_ON,
    HSTX_CMD_RAW_REPEAT | MODE_H_BACK_PORCH,
    SYNC_HSYNC_OFF,
    HSTX_CMD_TMDS | MODE_H_OUTPUT_PIXELS
};

// Blank line for VFP and VBP (6 words):
// back porch and active area merged since both are blank.
static uint32_t blank_cmd[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_HSYNC_OFF,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_HSYNC_ON,
    HSTX_CMD_RAW_REPEAT | (MODE_H_BACK_PORCH + MODE_H_OUTPUT_PIXELS),
    SYNC_HSYNC_OFF,
};

// VSYNC line (6 words):
// same structure as blank but with VSYNC active (positive polarity: V=1).
static uint32_t vsync_cmd[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_VSYNC_OFF,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_VSYNC_ON,
    HSTX_CMD_RAW_REPEAT | (MODE_H_BACK_PORCH + MODE_H_OUTPUT_PIXELS),
    SYNC_VSYNC_OFF,
};

// ----------------------------------------------------------------------------
// DMA logic
//
// Per-scanline CMD->DATA architecture: CMD reads DMA descriptors from a
// double-buffered per-scanline command buffer and writes them to DATA's
// Alias 3 registers via RING_WRITE. DATA executes each transfer to the
// HSTX FIFO. Each scanline buffer ends with a NULL stop marker that
// triggers an IRQ. The IRQ handler starts the next pre-prepared buffer
// and prepares the buffer for the scanline after that.

#define DMACH_CMD  0
#define DMACH_DATA 1

// Framebuffer: 640x360 RGB332 (230 KB), allocated in SRAM for direct DMA access.
static uint8_t framebuf[DVI_FRAME_WIDTH * DVI_FRAME_HEIGHT];

// Per-scanline command buffers (double-buffered).
// Active line: 3 descriptors (hsync + pixels + NULL stop) x 4 words = 12 words
// Blank/vsync: 2 descriptors (sync + NULL stop) x 4 words = 8 words
//
// Placed in scratch_y so that the IRQ handler (code in scratch_x) accesses
// data from a separate SRAM bank, avoiding I-bus / D-bus contention.
#define DMA_SCANLINE_BUF_WORDS 12
static uint32_t __scratch_y("") dma_scanline_buf[2][DMA_SCANLINE_BUF_WORDS] __attribute__((aligned(16)));

// DMA control words (initialized in dvi_start, used by prepare_scanline_dma)
static uint32_t __scratch_y("") ctrl_sync;
static uint32_t __scratch_y("") ctrl_pixel;
static uint32_t __scratch_y("") ctrl_stop;

static volatile uint32_t frame_count = 0;

// DWT cycle counter addresses (Cortex-M33)
#define DWT_CTRL   ((volatile uint32_t *)0xE0001000)
#define DWT_CYCCNT ((volatile uint32_t *)0xE0001004)
#define DEMCR      ((volatile uint32_t *)0xE000EDF0)

volatile uint32_t dvi_irq_max_cycles  = 0;
volatile uint32_t dvi_irq_last_cycles = 0;

static int __scratch_y("") cur_line = 0;       // current scanline (0 to MODE_V_TOTAL_LINES-1)
static int __scratch_y("") cur_desc_idx = 0;   // which dma_scanline_buf is active (0 or 1)

// Build DMA descriptors for a single scanline into the given buffer.
static void __force_inline __scratch_x("") prepare_scanline_dma(uint32_t *buf, int line) {
    const uint32_t fifo = (uintptr_t)&hstx_fifo_hw->fifo;

    if (line >= MODE_V_ACTIVE_LINES) {
        // Blank or vsync line: sync command + NULL stop
        uint32_t *cmd;
        uint32_t count;
        if (line >= MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH &&
            line < MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH) {
            cmd = vsync_cmd;
            count = count_of(vsync_cmd);
        } else {
            cmd = blank_cmd;
            count = count_of(blank_cmd);
        }
        buf[0] = ctrl_sync;
        buf[1] = fifo;
        buf[2] = count;
        buf[3] = (uintptr_t)cmd;
        buf[4] = ctrl_stop;
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 0;
    } else if (line < 2) {
        // Active line (full build for lines 0-1 after blanking period)
        buf[0] = ctrl_sync;
        buf[1] = fifo;
        buf[2] = count_of(hsync_cmd);
        buf[3] = (uintptr_t)hsync_cmd;
        buf[4] = ctrl_pixel;
        buf[5] = fifo;
        buf[6] = DVI_FRAME_WIDTH;
        buf[7] = (uintptr_t)&framebuf[(line >> 1) * DVI_FRAME_WIDTH];
        buf[8] = ctrl_stop;
        buf[9] = 0;
        buf[10] = 0;
        buf[11] = 0;
    } else {
        // Fast path: buffer still has active-line template from 2 lines ago,
        // only the framebuffer pointer needs updating.
        buf[7] = (uintptr_t)&framebuf[(line >> 1) * DVI_FRAME_WIDTH];
    }
}

void __scratch_x("") dma_irq_handler(void) {
    dma_hw->ints1 = 1u << DMACH_DATA;

    // Start the next pre-prepared descriptor buffer
    int next_idx = cur_desc_idx ^ 1;
    dma_hw->ch[DMACH_CMD].al3_read_addr_trig = (uintptr_t)dma_scanline_buf[next_idx];

    // The old descriptor buffer is now free to prepare
    int free_idx = cur_desc_idx;
    cur_desc_idx = next_idx;

    // Advance scanline counter
    if (++cur_line >= MODE_V_TOTAL_LINES) {
        cur_line = 0;
        frame_count++;
    }

    // Build descriptors for the scanline after the one we just started,
    // measuring execution time with the DWT cycle counter.
    int next_line = cur_line + 1;
    if (next_line >= MODE_V_TOTAL_LINES)
        next_line = 0;
    uint32_t cyc0 = *DWT_CYCCNT;
    prepare_scanline_dma(dma_scanline_buf[free_idx], next_line);
    uint32_t elapsed = *DWT_CYCCNT - cyc0;
    dvi_irq_last_cycles = elapsed;
    if (elapsed > dvi_irq_max_cycles)
        dvi_irq_max_cycles = elapsed;
}

// ----------------------------------------------------------------------------
// Public API

void dvi_start(void) {
    // Enable DWT cycle counter for IRQ timing measurement
    *DEMCR     |= (1u << 24);  // TRCENA: enable DWT
    *DWT_CTRL  |= 1u;          // CYCCNTENA: enable cycle counter
    *DWT_CYCCNT = 0;

    // Configure HSTX's TMDS encoder for RGB332
    hstx_ctrl_hw->expand_tmds =
        2  << HSTX_CTRL_EXPAND_TMDS_L2_NBITS_LSB |
        0  << HSTX_CTRL_EXPAND_TMDS_L2_ROT_LSB   |
        2  << HSTX_CTRL_EXPAND_TMDS_L1_NBITS_LSB |
        29 << HSTX_CTRL_EXPAND_TMDS_L1_ROT_LSB   |
        1  << HSTX_CTRL_EXPAND_TMDS_L0_NBITS_LSB |
        26 << HSTX_CTRL_EXPAND_TMDS_L0_ROT_LSB;

    // Pixels (TMDS): 2 shifts of 8 bits per refill -> 2 identical TMDS pixels
    // per DMA read (horizontal 2x scaling). Control symbols (RAW) are an
    // entire 32-bit word.
    hstx_ctrl_hw->expand_shift =
        2 << HSTX_CTRL_EXPAND_SHIFT_ENC_N_SHIFTS_LSB |
        8 << HSTX_CTRL_EXPAND_SHIFT_ENC_SHIFT_LSB |
        1 << HSTX_CTRL_EXPAND_SHIFT_RAW_N_SHIFTS_LSB |
        0 << HSTX_CTRL_EXPAND_SHIFT_RAW_SHIFT_LSB;

    // Serial output: CLKDIV=5, 5 shifts per HSTX cycle, 2 bits per shift.
    // At clk_hstx=372 MHz: bit clock = 372*2 = 744 Mbps ~ 742.5 Mbps (720p).
    hstx_ctrl_hw->csr = 0;
    hstx_ctrl_hw->csr =
        HSTX_CTRL_CSR_EXPAND_EN_BITS |
        5u << HSTX_CTRL_CSR_CLKDIV_LSB |
        5u << HSTX_CTRL_CSR_N_SHIFTS_LSB |
        2u << HSTX_CTRL_CSR_SHIFT_LSB |
        HSTX_CTRL_CSR_EN_BITS;

    // HSTX outputs 0 through 7 appear on GPIO 12 through 19.
    // Pinout:
    //
    //   GP12 CK-  GP13 CK+
    //   GP14 D0-  GP15 D0+
    //   GP16 D1-  GP17 D1+
    //   GP18 D2-  GP19 D2+

    // Clock on GP12 (CK-) and GP13 (CK+):
    hstx_ctrl_hw->bit[0] = HSTX_CTRL_BIT0_CLK_BITS | HSTX_CTRL_BIT0_INV_BITS;
    hstx_ctrl_hw->bit[1] = HSTX_CTRL_BIT0_CLK_BITS;
    // TMDS lanes 0-2 on GP14-GP19 sequentially (D0, D1, D2).
    // Within each pair, the '-' pin (lower GPIO) is inverted, '+' pin is not.
    for (uint lane = 0; lane < 3; ++lane) {
        int bit = 2 + lane * 2;
        uint32_t sel = (lane * 10    ) << HSTX_CTRL_BIT0_SEL_P_LSB |
                       (lane * 10 + 1) << HSTX_CTRL_BIT0_SEL_N_LSB;
        hstx_ctrl_hw->bit[bit    ] = sel | HSTX_CTRL_BIT0_INV_BITS;
        hstx_ctrl_hw->bit[bit + 1] = sel;
    }

    for (int i = 12; i <= 19; ++i) {
        gpio_set_function(i, GPIO_FUNC_HSTX);
        gpio_set_drive_strength(i, GPIO_DRIVE_STRENGTH_8MA);
    }

    // Build DMA control words for scanline descriptors.
    // All DATA transfers chain back to CMD and use IRQ_QUIET.
    dma_channel_config c;

    // CTRL_SYNC: sync/timing data (SIZE_32, DREQ_HSTX)
    c = dma_channel_get_default_config(DMACH_DATA);
    channel_config_set_chain_to(&c, DMACH_CMD);
    channel_config_set_dreq(&c, DREQ_HSTX);
    channel_config_set_irq_quiet(&c, true);
    channel_config_set_high_priority(&c, true);
    ctrl_sync = channel_config_get_ctrl_value(&c);

    // CTRL_PIXEL: pixel data (SIZE_8, DREQ_HSTX) for 2x horizontal scaling
    channel_config_set_transfer_data_size(&c, DMA_SIZE_8);
    ctrl_pixel = channel_config_get_ctrl_value(&c);

    // CTRL_STOP: NULL stop marker (TREQ_FORCE, triggers IRQ via null trigger)
    channel_config_set_transfer_data_size(&c, DMA_SIZE_32);
    channel_config_set_dreq(&c, DREQ_FORCE);
    ctrl_stop = channel_config_get_ctrl_value(&c);

    // Prepare initial scanline buffers (scanline 0 and 1)
    prepare_scanline_dma(dma_scanline_buf[0], 0);
    prepare_scanline_dma(dma_scanline_buf[1], 1);

    // Configure CMD channel: reads descriptors from scanline buffer,
    // writes to DATA channel's Alias 3 registers via RING_WRITE.
    c = dma_channel_get_default_config(DMACH_CMD);
    channel_config_set_chain_to(&c, DMACH_CMD);
    channel_config_set_dreq(&c, DREQ_FORCE);
    channel_config_set_ring(&c, true, 4);  // Ring on write, 2^4 = 16 bytes
    channel_config_set_high_priority(&c, true);
    channel_config_set_write_increment(&c, true);
    dma_channel_configure(
        DMACH_CMD,
        &c,
        &dma_hw->ch[DMACH_DATA].al3_ctrl,
        dma_scanline_buf[0],
        4,
        false
    );

    // DATA channel IRQ: fires once per scanline at NULL stop marker.
    // Using DMA_IRQ_1 to avoid conflicts with other DMA users on IRQ_0.
    dma_hw->ints1 = 1u << DMACH_DATA;
    dma_hw->inte1 = 1u << DMACH_DATA;
    irq_set_exclusive_handler(DMA_IRQ_1, dma_irq_handler);
    irq_set_priority(DMA_IRQ_1, 0x00);
    irq_set_enabled(DMA_IRQ_1, true);

    bus_ctrl_hw->priority = BUSCTRL_BUS_PRIORITY_DMA_W_BITS | BUSCTRL_BUS_PRIORITY_DMA_R_BITS;

    // Start by triggering CMD to process the first scanline
    dma_hw->ch[DMACH_CMD].al3_read_addr_trig = (uintptr_t)dma_scanline_buf[0];
}

uint8_t *dvi_get_framebuffer(void) {
    return framebuf;
}

uint32_t dvi_get_frame_count(void) {
    return frame_count;
}

void dvi_wait_vsync(void) {
    uint32_t last = frame_count;
    while (frame_count == last) {
        __wfi();
    }
}
