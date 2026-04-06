// Copyright (c) 2026 Shunsuke Michii
//
// DVI output driver using CMD->DATA DMA architecture with HSTX TMDS encoder.
// Outputs 640x480 @ 60Hz DVI.
//
// Supports two modes:
//   GRAPHICS: 320x240 RGB332 framebuffer, 2x scaled to 640x480
//   TEXT:  text VRAM rendered at native 640x480
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

#include <string.h>

#define STR_HELPER(x) #x
#define STR(x) STR_HELPER(x)

#include "uni2jis_table.h"

// ----------------------------------------------------------------------------
// DVI constants

// TMDS control symbols encode sync signals as 10-bit patterns.
// On lane 0 (blue), the two data bits carry HSYNC (D0) and VSYNC (D1).
// Lanes 1 and 2 always transmit CTRL_00 during sync periods.
#define TMDS_CTRL_00 0x354u // D1=0, D0=0
#define TMDS_CTRL_01 0x0abu // D1=0, D0=1
#define TMDS_CTRL_10 0x154u // D1=1, D0=0
#define TMDS_CTRL_11 0x2abu // D1=1, D0=1

// Combined 30-bit sync words for all 3 TMDS lanes (10 bits each).
#define SYNC_V0_H0 (TMDS_CTRL_00 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))
#define SYNC_V0_H1 (TMDS_CTRL_01 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))
#define SYNC_V1_H0 (TMDS_CTRL_10 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))
#define SYNC_V1_H1 (TMDS_CTRL_11 | (TMDS_CTRL_00 << 10) | (TMDS_CTRL_00 << 20))

// 640x480 @ 60Hz uses negative sync polarity: 0 = asserted, 1 = inactive.
#define SYNC_HSYNC_OFF SYNC_V1_H1 // H=1 deasserted, V=1 deasserted
#define SYNC_HSYNC_ON SYNC_V1_H0  // H=0 asserted,   V=1 deasserted
#define SYNC_VSYNC_OFF SYNC_V0_H1 // H=1 deasserted, V=0 asserted
#define SYNC_VSYNC_ON SYNC_V0_H0  // H=0 asserted,   V=0 asserted

// 640x480 @ 60Hz timing (pixel clock = sys_clk / 5; 125 MHz -> 25 MHz)
// H total = 16 + 96 + 48 + 640 = 800 pixels
// V total = 10 + 2 + 33 + 480 = 525 lines
#define MODE_H_FRONT_PORCH 16
#define MODE_H_SYNC_WIDTH 96
#define MODE_H_BACK_PORCH 48
#define MODE_H_ACTIVE_PIXELS 640

#define MODE_V_FRONT_PORCH 10
#define MODE_V_SYNC_WIDTH 2
#define MODE_V_BACK_PORCH 33
#define MODE_V_ACTIVE_LINES 480
#define MODE_V_TOTAL_LINES                                                     \
  (MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH +              \
   MODE_V_BACK_PORCH)

// HSTX command expander opcodes (upper 4 bits of command word)
#define HSTX_CMD_RAW_REPEAT (0x1u << 12) // Repeat raw data N times
#define HSTX_CMD_TMDS (0x2u << 12)       // TMDS-encode N pixels from FIFO

#define GPIO_FUNC_HSTX 0

// ----------------------------------------------------------------------------
// HSTX command templates

// HSYNC prefix for active lines (7 words):
// front porch, sync pulse, back porch, then start TMDS pixel encoding.
static uint32_t hsync_cmd[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH, SYNC_HSYNC_OFF,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,  SYNC_HSYNC_ON,
    HSTX_CMD_RAW_REPEAT | MODE_H_BACK_PORCH,  SYNC_HSYNC_OFF,
    HSTX_CMD_TMDS | MODE_H_ACTIVE_PIXELS};

// Blank line for VFP and VBP (6 words):
static uint32_t blank_cmd[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_HSYNC_OFF,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_HSYNC_ON,
    HSTX_CMD_RAW_REPEAT | (MODE_H_BACK_PORCH + MODE_H_ACTIVE_PIXELS),
    SYNC_HSYNC_OFF,
};

// VSYNC line (6 words):
static uint32_t vsync_cmd[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_VSYNC_OFF,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_VSYNC_ON,
    HSTX_CMD_RAW_REPEAT | (MODE_H_BACK_PORCH + MODE_H_ACTIVE_PIXELS),
    SYNC_VSYNC_OFF,
};

// ----------------------------------------------------------------------------
// Mode state

static dvi_mode_t active_mode;
static volatile int next_mode = -1; // -1 = no pending switch

// ----------------------------------------------------------------------------
// DMA logic
//
// Two-channel CMD->DATA DMA architecture:
//   DMACH_CMD  (0): reads DMA descriptors, writes to DATA's Alias 3 registers
//   DMACH_DATA (1): executes transfers to HSTX FIFO

#define DMACH_CMD 0
#define DMACH_DATA 1

// Batch rendering constants
#define BATCH_SIZE 4
#define LINE_BUF_COUNT (BATCH_SIZE * 2)

// Per-batch command buffers (double-buffered).
// In main SRAM to avoid SCRATCH_Y contention with CPU ctrl word accesses.
// CMD DMA reads these in brief bursts (4 words per group, DREQ_FORCE).
// Batch layout for N=4 active lines: N x 8 words (sync+pixel) + 4 (stop) = 36.
// Single-line (blanking) uses only the first 12 words.
#define DMA_BATCH_BUF_WORDS (BATCH_SIZE * 8 + 4)
static uint32_t dma_scanline_buf[2][DMA_BATCH_BUF_WORDS]
    __attribute__((aligned(16)));

// DMA control words (read by CPU in prepare_scanline_dma)
static uint32_t ctrl_sync;
static uint32_t ctrl_pixel; // DMA_SIZE_8 for pixel mode (byte replication = 2x)
static uint32_t ctrl_text_pixel; // DMA_SIZE_32 for text mode (4 packed pixels)
static uint32_t ctrl_stop;

static volatile uint32_t frame_count = 0;

// DWT cycle counter addresses (Cortex-M33)
#define DWT_CTRL ((volatile uint32_t *)0xE0001000)
#define DWT_CYCCNT ((volatile uint32_t *)0xE0001004)
#define DEMCR ((volatile uint32_t *)0xE000EDF0)

volatile uint32_t dvi_irq_max_cycles = 0;
volatile uint32_t dvi_fifo_empty_count = 0;

// Text mode render timing (per line)
volatile uint32_t dvi_render_max_cycles = 0;
volatile uint32_t dvi_render_last_cycles = 0;
volatile uint32_t dvi_render_min_cycles = 0xFFFFFFFF;

// Batch render total (sum of BATCH_SIZE line renders in one IRQ)
volatile uint32_t dvi_batch_render_max_cycles = 0;
volatile uint32_t dvi_batch_render_last_cycles = 0;

// IRQ-to-IRQ interval measurement
volatile uint32_t dvi_irq_interval_min = 0xFFFFFFFF;
volatile uint32_t dvi_irq_interval_max = 0;
static uint32_t last_irq_timestamp = 0;

// FIFO underflow diagnostics
#define FIFO_EMPTY_LOG_SIZE 8
volatile uint32_t dvi_fifo_empty_log[FIFO_EMPTY_LOG_SIZE]; // scanline numbers
volatile uint32_t dvi_fifo_empty_log_idx = 0;
volatile uint32_t dvi_fifo_min_level =
    0xFF; // minimum FIFO level seen at IRQ entry

static int cur_line = 0;
static int cur_desc_idx = 0;

// Blanking flag: when true, all active lines output black (blank_cmd only).
// Set by Core 0 before flash operations to prevent Core 1 from accessing
// flash-resident .rodata during rendering.
static volatile bool dvi_blanking = false;

// ----------------------------------------------------------------------------
// Pixel mode data

// Screen buffer: shared memory between graphics and text modes.
// Graphics mode uses screenbuf.framebuffer (640x480 RGB332).
// Text mode reuses the same memory as per-position glyph bitmap.
static union {
  uint8_t framebuffer[DVI_GRAPHICS_MAX_WIDTH * DVI_GRAPHICS_MAX_HEIGHT];
  uint8_t glyph_bitmap[DVI_TEXT_MAX_ROWS * 13 * DVI_TEXT_MAX_COLS];
} screenbuf;
static uint8_t *back_framebuf = NULL;
static bool graphics_dirty = false;

// Runtime graphics scale: 1 = 640x480 native, 2 = 320x240 (2x scaled)
static int graphics_scale = 1;
static volatile int next_graphics_scale = -1;

// ----------------------------------------------------------------------------
// Text mode data

// Double-buffered text VRAM: Core 0 writes to write_vram (back buffer),
// Core 1 reads from render_vram (front buffer). Pointer swap at VBlank.
static dvi_text_cell_t text_vram_a[DVI_TEXT_MAX_ROWS * DVI_TEXT_MAX_COLS];
static dvi_text_cell_t text_vram_b[DVI_TEXT_MAX_ROWS * DVI_TEXT_MAX_COLS];
static dvi_text_cell_t *write_vram = text_vram_a;
static dvi_text_cell_t *volatile render_vram = text_vram_a;
static int text_cols = DVI_TEXT_MAX_COLS;
static int text_rows = DVI_TEXT_MAX_ROWS;

// All-black line buffer for DVI blanking mode (flash write safety).
// Used as pixel data source when dvi_blanking is true, avoiding any
// flash-resident data access during rendering.
static uint8_t blank_line_buf[MODE_H_ACTIVE_PIXELS + 4]
    __attribute__((aligned(4)));

// Scanline output buffers in main SRAM (8-bank striped).
// Stride = 644 bytes (640 data + 4 padding).  Word offset = 161 per buffer,
// so buf[i] maps to SRAM bank (161*i % 8) = {0,1,2,3,4,5,6,7}: all 8 buffers
// land on different banks, giving zero bank collisions between any pair.
// 2N=8 buffers are needed for batch rendering (N=4): one set of N buffers
// being DMA'd while the CPU renders into the other N buffers.
#define LINE_BUF_STRIDE (MODE_H_ACTIVE_PIXELS + 4)
static uint8_t line_buf[LINE_BUF_COUNT][LINE_BUF_STRIDE]
    __attribute__((aligned(4)));
static int line_buf_next = 0;

static const dvi_font_t *text_font;
static const dvi_font_t *text_wide_font;
static uint8_t text_palette[16];

// 12px renderer constants
#define TEXT_GLYPH_HEIGHT_12WIDE 13
#define TEXT_12WIDE_COLS (MODE_H_ACTIVE_PIXELS / 6) // 106

// Row-major narrow font cache in SRAM (regular + bold).
// Layout: [glyph_y * 512 + ch]. Regular at 0-255, bold at 256-511.
#define NARROW_CACHE_STRIDE 512
static uint8_t narrow_row_cache[TEXT_GLYPH_HEIGHT_12WIDE * NARROW_CACHE_STRIDE];

// Per-row wide character flag for narrow-only / mixed path dispatch
// (double-buffered).
static uint8_t row_has_wide_a[DVI_TEXT_MAX_ROWS];
static uint8_t row_has_wide_b[DVI_TEXT_MAX_ROWS];
static uint8_t *write_row_has_wide = row_has_wide_a;
static uint8_t *volatile render_row_has_wide = row_has_wide_a;

// Per-position glyph bitmap constants.
// Layout: [(physical_row * GLYPH_HEIGHT + glyph_y) * STRIDE + col]
// Wide-left cell stores low 8 bits, wide-right stores high 8 bits of the
// 12-bit glyph row. ldrh at wide-left reads the full 16-bit value.
#define GLYPH_BITMAP_STRIDE DVI_TEXT_MAX_COLS
#define GLYPH_BITMAP_SIZE \
    (DVI_TEXT_MAX_ROWS * TEXT_GLYPH_HEIGHT_12WIDE * GLYPH_BITMAP_STRIDE)

// Ring buffer scroll offset (double-buffered).
// Logical row N maps to physical row (N + scroll_offset) % text_rows.
static int write_scroll_offset = 0;
static volatile int render_scroll_offset = 0;

// Pending buffer swap request from Core 0, processed at VBlank by Core 1.
static volatile bool swap_pending = false;

// Pre-expanded palette: RGB332 byte replicated to all 4 lanes.
static uint32_t text_palette32[16];

// Pre-expanded nibble mask table in SCRATCH_Y (SRAM9, separate bus port).
// Maps font byte (0-255) to pre-computed (mask_hi, mask_lo) pair.
// Eliminates 2 Main SRAM reads per char by moving lookups off the DMA bus.
static uint32_t font_byte_mask[256][2]
    __attribute__((section(".scratch_y.font_byte_mask"), aligned(8)));

// VGA-compatible default palette
static const uint8_t default_palette[16] = {
    0x00, // 0  Black
    0x03, // 1  Blue
    0x1C, // 2  Green
    0x1F, // 3  Cyan
    0xE0, // 4  Red
    0xE3, // 5  Magenta
    0xFC, // 6  Brown/Yellow
    0x92, // 7  Light Gray
    0x49, // 8  Dark Gray
    0x4F, // 9  Light Blue
    0x3E, // 10 Light Green
    0x3F, // 11 Light Cyan
    0xEC, // 12 Light Red
    0xEF, // 13 Light Magenta
    0xFE, // 14 Yellow
    0xFF, // 15 White
};

static void update_palette32(void) {
  for (int i = 0; i < 16; i++)
    text_palette32[i] = text_palette[i] * 0x01010101u;
}

static void init_font_byte_mask(void) {
  // Nibble-to-mask: each bit in a 4-bit nibble selects 0xFF or 0x00 in
  // the corresponding byte lane. Computed inline to avoid a static array.
  static const uint32_t nmask[16] = {
      0x00000000, 0xFF000000, 0x00FF0000, 0xFFFF0000, 0x0000FF00, 0xFF00FF00,
      0x00FFFF00, 0xFFFFFF00, 0x000000FF, 0xFF0000FF, 0x00FF00FF, 0xFFFF00FF,
      0x0000FFFF, 0xFF00FFFF, 0x00FFFFFF, 0xFFFFFFFF,
  };
  for (int b = 0; b < 256; b++) {
    font_byte_mask[b][0] = nmask[b >> 4];
    font_byte_mask[b][1] = nmask[b & 0x0C];
  }
}

// Map logical row to physical row in the ring buffer.
static inline int physical_row(int logical_row, int offset) {
  int r = logical_row + offset;
  return r >= text_rows ? r - text_rows : r;
}

// Render a wide glyph's bitmap from flash font into the per-position
// glyph bitmap at the given physical row and column.
static void render_wide_glyph_at(int col, int phys_row, uint16_t linear_jis,
                                 const dvi_font_t *font, bool bold) {
  if (!font)
    return;
  int bytes_per_glyph = font->glyph_height * 2;
  int stride = bytes_per_glyph * 2;
  const uint8_t *src =
      font->bitmap + (linear_jis - font->first_char) * stride;
  if (bold)
    src += bytes_per_glyph;
  for (int y = 0; y < font->glyph_height; y++) {
    int base =
        (phys_row * TEXT_GLYPH_HEIGHT_12WIDE + y) * GLYPH_BITMAP_STRIDE + col;
    screenbuf.glyph_bitmap[base] = src[y * 2];
    screenbuf.glyph_bitmap[base + 1] = src[y * 2 + 1];
  }
}

// ----------------------------------------------------------------------------
// 12px mixed-width renderer (6px half-width + 12px full-width, 106 columns)
//
// Renders a scanline using 6px half-width (ISO 8859-1) and 12px full-width
// (JIS X 0208) glyphs at 640x480 native resolution. Half-width characters
// occupy 1 cell (6px), full-width characters occupy 2 cells (12px).
//
// Rendering formula (branchless pixel selection via font_byte_mask LUT):
//   pixel = bg4 ^ (xor4 & font_byte_mask[byte][0..1])
//
// Two paths:
//   Narrow-only: ldrd pair processing with per-cell attr checks
//   Mixed:       single-cell dispatch, glyph_ptr for wide characters

static void __scratch_x("")
    render_text_scanline_12wide(int scanline, uint8_t *out) {
  int text_row = scanline / TEXT_GLYPH_HEIGHT_12WIDE;
  int glyph_y = scanline % TEXT_GLYPH_HEIGHT_12WIDE;

  // Ring buffer: map logical text_row to physical row.
  int phys_row = text_row + render_scroll_offset;
  if (phys_row >= text_rows)
    phys_row -= text_rows;

  const uint32_t *cell =
      (const uint32_t *)&render_vram[phys_row * TEXT_12WIDE_COLS];
  const uint32_t *end = cell + TEXT_12WIDE_COLS;
  uint8_t *out_end = out + MODE_H_ACTIVE_PIXELS;

  // SRAM cache row: regular at [0..255], bold at [256..511].
  const uint8_t *narrow_row =
      narrow_row_cache + (glyph_y * NARROW_CACHE_STRIDE);

  const uint32_t *pal32 = text_palette32;

  // Force first attr lookup (bitwise NOT guarantees mismatch).
  uint32_t prev_attr = ~(uint32_t)(uint8_t)(*cell >> 16);
  uint32_t bg4 = 0, xor4 = 0;
  uint32_t t1, t2;

  if (!render_row_has_wide[phys_row]) {
    // NARROW-ONLY PATH WITH ATTR CHECKS
    // Processes 2 cells per iteration via ldrd. Uses font_byte_mask in
    // SCRATCH_Y for reduced Main SRAM contention.
    const uint32_t *exp = (const uint32_t *)font_byte_mask;
    uint32_t t3, t4;
    __asm__ volatile(

        // Loop top: load 2 cells via ldrd
        "10:\n\t"
        "ldrd   %[t1], %[t3], [%[cell]]\n\t"
        "adds   %[cell], #8\n\t"
        "ubfx   %[t2], %[t1], #16, #8\n\t"
        "cmp    %[t2], %[prev]\n\t"
        "bne    13f\n\t"

        // First character (narrow 6px)
        "12:\n\t"
        "uxth   %[t2], %[t1]\n\t"
        "ldrb   %[t2], [%[nrow], %[t2]]\n\t"
        "adds   %[out], #6\n\t"
        "add    %[t2], %[exp], %[t2], lsl #3\n\t"
        "ldrd   %[t1], %[t4], [%[t2]]\n\t"
        "and.w  %[t1], %[t1], %[xor]\n\t"
        "eor.w  %[t1], %[t1], %[bg]\n\t"
        "str    %[t1], [%[out], #-6]\n\t"
        "and.w  %[t4], %[t4], %[xor]\n\t"
        "eor.w  %[t4], %[t4], %[bg]\n\t"
        "str    %[t4], [%[out], #-2]\n\t"

        // Second character attr check
        "ubfx   %[t2], %[t3], #16, #8\n\t"
        "cmp    %[t2], %[prev]\n\t"
        "bne    14f\n\t"

        // Second character (narrow 6px)
        "15:\n\t"
        "uxth   %[t2], %[t3]\n\t"
        "ldrb   %[t2], [%[nrow], %[t2]]\n\t"
        "adds   %[out], #6\n\t"
        "add    %[t2], %[exp], %[t2], lsl #3\n\t"
        "ldrd   %[t1], %[t4], [%[t2]]\n\t"
        "and.w  %[t1], %[t1], %[xor]\n\t"
        "eor.w  %[t1], %[t1], %[bg]\n\t"
        "str    %[t1], [%[out], #-6]\n\t"
        "and.w  %[t4], %[t4], %[xor]\n\t"
        "cmp    %[end], %[cell]\n\t"
        "eor.w  %[t4], %[t4], %[bg]\n\t"
        "str    %[t4], [%[out], #-2]\n\t"
        "bhi    10b\n\t"
        "b      16f\n\t"

        // Attr change handler for first cell (cold path)
        "13:\n\t"
        "mov    %[prev], %[t2]\n\t"
        "and    %[t2], %[t2], #0x0F\n\t"
        "ldr    %[bg], [%[pal], %[t2], lsl #2]\n\t"
        "lsrs   %[t2], %[prev], #4\n\t"
        "ldr    %[t2], [%[pal], %[t2], lsl #2]\n\t"
        "eor    %[xor], %[bg], %[t2]\n\t"
        "b      12b\n\t"

        // Attr change handler for second cell (cold path)
        "14:\n\t"
        "mov    %[prev], %[t2]\n\t"
        "and    %[t2], %[t2], #0x0F\n\t"
        "ldr    %[bg], [%[pal], %[t2], lsl #2]\n\t"
        "lsrs   %[t2], %[prev], #4\n\t"
        "ldr    %[t2], [%[pal], %[t2], lsl #2]\n\t"
        "eor    %[xor], %[bg], %[t2]\n\t"
        "b      15b\n\t"

        "16:\n\t" // done

        : [cell] "+r"(cell), [out] "+r"(out), [bg] "+r"(bg4),
          [xor] "+r"(xor4), [prev] "+r"(prev_attr), [t1] "=&r"(t1),
          [t2] "=&r"(t2), [t3] "=&r"(t3), [t4] "=&r"(t4)
        : [end] "r"(end), [exp] "r"(exp), [nrow] "r"(narrow_row),
          [pal] "r"(pal32)
        : "cc", "memory");

  } else {
    // MIXED PATH (narrow 6px + wide 12px) WITH ATTR CHECKS
    // Wide glyphs read from per-position glyph bitmap (sequential access).
    // Narrow uses narrow_row_cache. glyph_ptr advances by 1 for narrow,
    // 2 for wide to stay synchronized with cell position.
    const uint8_t *glyph_ptr =
        screenbuf.glyph_bitmap +
        (phys_row * TEXT_GLYPH_HEIGHT_12WIDE + glyph_y) * GLYPH_BITMAP_STRIDE;
    const uint32_t *exp = (const uint32_t *)font_byte_mask;

    uint32_t t3, t4;
    __asm__ volatile(

        // Loop top: load 1 cell
        "1:\n\t"
        "ldr    %[t1], [%[cell]]\n\t"
        "adds   %[cell], #4\n\t"
        "ubfx   %[t2], %[t1], #16, #8\n\t"
        "cmp    %[t2], %[prev]\n\t"
        "bne    3f\n\t"

        // Dispatch: narrow vs wide
        "2:\n\t"
        "tst    %[t1], #0x03000000\n\t"
        "bne    4f\n\t"

        // Narrow (6px) sub-path
        "uxth   %[t2], %[t1]\n\t"
        "ldrb   %[t2], [%[nrow], %[t2]]\n\t"
        "adds   %[gptr], #1\n\t"
        "adds   %[out], #6\n\t"
        "add    %[t2], %[exp], %[t2], lsl #3\n\t"
        "ldrd   %[t1], %[t4], [%[t2]]\n\t"
        "and.w  %[t1], %[t1], %[xor]\n\t"
        "eor.w  %[t1], %[t1], %[bg]\n\t"
        "str    %[t1], [%[out], #-6]\n\t"
        "and.w  %[t4], %[t4], %[xor]\n\t"
        "cmp    %[end], %[cell]\n\t"
        "eor.w  %[t4], %[t4], %[bg]\n\t"
        "str    %[t4], [%[out], #-2]\n\t"
        "bhi    1b\n\t"
        "b      6f\n\t"

        // Wide (12px) sub-path
        // Load 16-bit glyph row from per-position bitmap.
        "4:\n\t"
        "ldrh   %[t1], [%[gptr]]\n\t"
        "adds   %[gptr], #2\n\t"
        "adds   %[cell], #4\n\t"
        "adds   %[out], #12\n\t"
        // Pixels 0-3
        "uxtb   %[t2], %[t1]\n\t"
        "add    %[t2], %[exp], %[t2], lsl #3\n\t"
        "ldr    %[t3], [%[t2]]\n\t"
        "and    %[t2], %[t1], #0x0F\n\t"
        "add    %[t2], %[exp], %[t2], lsl #7\n\t"
        "and.w  %[t3], %[t3], %[xor]\n\t"
        "eor.w  %[t3], %[t3], %[bg]\n\t"
        "str    %[t3], [%[out], #-12]\n\t"
        // Pixels 4-7
        "ldr    %[t2], [%[t2]]\n\t"
        "lsrs   %[t3], %[t1], #8\n\t"
        "add    %[t3], %[exp], %[t3], lsl #3\n\t"
        "and.w  %[t2], %[t2], %[xor]\n\t"
        "eor.w  %[t2], %[t2], %[bg]\n\t"
        "str    %[t2], [%[out], #-8]\n\t"
        // Pixels 8-11
        "ldr    %[t3], [%[t3]]\n\t"
        "cmp    %[end], %[cell]\n\t"
        "and.w  %[t3], %[t3], %[xor]\n\t"
        "eor.w  %[t3], %[t3], %[bg]\n\t"
        "str    %[t3], [%[out], #-4]\n\t"
        "bhi    1b\n\t"
        "b      6f\n\t"

        // Attr change handler (cold path)
        "3:\n\t"
        "mov    %[prev], %[t2]\n\t"
        "and    %[t2], %[t2], #0x0F\n\t"
        "ldr    %[bg], [%[pal], %[t2], lsl #2]\n\t"
        "lsrs   %[t2], %[prev], #4\n\t"
        "ldr    %[t2], [%[pal], %[t2], lsl #2]\n\t"
        "eor    %[xor], %[bg], %[t2]\n\t"
        "b      2b\n\t"

        "6:\n\t" // done

        : [cell] "+r"(cell), [out] "+r"(out), [bg] "+r"(bg4),
          [xor] "+r"(xor4), [prev] "+r"(prev_attr), [gptr] "+r"(glyph_ptr),
          [t1] "=&r"(t1), [t2] "=&r"(t2), [t3] "=&r"(t3), [t4] "=&r"(t4)
        : [end] "r"(end), [exp] "r"(exp), [nrow] "r"(narrow_row),
          [pal] "r"(pal32)
        : "cc", "memory");
  }

  // Fill remaining pixels with black (inline to avoid flash memset).
  for (uint8_t *p = out; p < out_end; p += 4)
    __asm__ volatile("str %1, [%0]" : : "r"(p), "r"(0) : "memory");
}

// ----------------------------------------------------------------------------
// DMA batch descriptor preparation
//
// Active lines are batched: BATCH_SIZE scanlines per IRQ (120 IRQs for 480
// lines).  Blanking lines remain single (45 IRQs for VFP+VSYNC+VBP).
// Total: 165 IRQs per frame (down from 525).
//
// Batch descriptor layout (active, 36 words):
//   buf[ 0.. 7]: sync + pixel for line 0
//   buf[ 8..15]: sync + pixel for line 1
//   buf[16..23]: sync + pixel for line 2
//   buf[24..31]: sync + pixel for line 3
//   buf[32..35]: NULL stop (triggers IRQ)
//
// Blanking descriptor layout (8 words):
//   buf[0..3]: sync command (blank_cmd or vsync_cmd)
//   buf[4..7]: NULL stop (triggers IRQ)

// First line of each descriptor buffer (tracks what each buffer contains).
static int buf_first_line[2];

// Build DMA descriptors for a batch of scanlines.
static void __force_inline __scratch_x("")
    prepare_batch_dma(uint32_t *buf, int first_line) {
  const uint32_t fifo = (uintptr_t)&hstx_fifo_hw->fifo;

  if (first_line >= MODE_V_ACTIVE_LINES) {
    // Single blanking or vsync line (no rendering needed)
    uint32_t *cmd;
    uint32_t count;
    if (first_line >= MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH &&
        first_line <
            MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH) {
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
  } else if (dvi_blanking && active_mode == DVI_MODE_TEXT) {
    // Blanking mode (text only): same descriptor format as text mode,
    // but all lines point to the all-black buffer instead of rendered data.
    // No rendering call, no flash-resident data access.
    // Graphics mode is safe without blanking (framebuffer is in SRAM).
    for (int i = 0; i < BATCH_SIZE; i++) {
      int grp = i * 8;
      buf[grp + 0] = ctrl_sync;
      buf[grp + 1] = fifo;
      buf[grp + 2] = count_of(hsync_cmd);
      buf[grp + 3] = (uintptr_t)hsync_cmd;
      buf[grp + 4] = ctrl_text_pixel;
      buf[grp + 5] = fifo;
      buf[grp + 6] = MODE_H_ACTIVE_PIXELS / sizeof(uint32_t);
      buf[grp + 7] = (uintptr_t)blank_line_buf;
    }
    buf[BATCH_SIZE * 8 + 0] = ctrl_stop;
    buf[BATCH_SIZE * 8 + 1] = 0;
    buf[BATCH_SIZE * 8 + 2] = 0;
    buf[BATCH_SIZE * 8 + 3] = 0;
  } else if (active_mode == DVI_MODE_TEXT) {
    // Text mode: render BATCH_SIZE scanlines into line buffers.
    // Full descriptor build for the first two batches of each frame
    // (first_line < BATCH_SIZE * 2) to initialize both double-buffered
    // descriptor buffers.  Subsequent batches use the fast path (pointer
    // update only).
    int full_build = (first_line < BATCH_SIZE * 2);

#ifdef DVI_DIAGNOSTICS
    uint32_t batch_cyc0 = *DWT_CYCCNT;
#endif
    for (int i = 0; i < BATCH_SIZE; i++) {
      int idx = line_buf_next;
      line_buf_next = (line_buf_next + 1) % LINE_BUF_COUNT;
      int grp = i * 8;

#ifdef DVI_DIAGNOSTICS
      uint32_t cyc0 = *DWT_CYCCNT;
#endif
      render_text_scanline_12wide(first_line + i, line_buf[idx]);
#ifdef DVI_DIAGNOSTICS
      uint32_t elapsed = *DWT_CYCCNT - cyc0;
      dvi_render_last_cycles = elapsed;
      if (elapsed > dvi_render_max_cycles)
        dvi_render_max_cycles = elapsed;
      if (elapsed < dvi_render_min_cycles)
        dvi_render_min_cycles = elapsed;
#endif

      if (full_build) {
        buf[grp + 0] = ctrl_sync;
        buf[grp + 1] = fifo;
        buf[grp + 2] = count_of(hsync_cmd);
        buf[grp + 3] = (uintptr_t)hsync_cmd;
        buf[grp + 4] = ctrl_text_pixel;
        buf[grp + 5] = fifo;
        buf[grp + 6] = MODE_H_ACTIVE_PIXELS / sizeof(uint32_t);
        buf[grp + 7] = (uintptr_t)line_buf[idx];
      } else {
        buf[grp + 7] = (uintptr_t)line_buf[idx];
      }
    }
#ifdef DVI_DIAGNOSTICS
    uint32_t batch_elapsed = *DWT_CYCCNT - batch_cyc0;
    dvi_batch_render_last_cycles = batch_elapsed;
    if (batch_elapsed > dvi_batch_render_max_cycles)
      dvi_batch_render_max_cycles = batch_elapsed;
#endif
    if (full_build) {
      buf[BATCH_SIZE * 8 + 0] = ctrl_stop;
      buf[BATCH_SIZE * 8 + 1] = 0;
      buf[BATCH_SIZE * 8 + 2] = 0;
      buf[BATCH_SIZE * 8 + 3] = 0;
    }
  } else {
    // Graphics mode: batch of BATCH_SIZE lines (no rendering, pointer only)
    int full_build = (first_line < BATCH_SIZE * 2);

    for (int i = 0; i < BATCH_SIZE; i++) {
      int line = first_line + i;
      int grp = i * 8;

      int scale = graphics_scale;
      int gw = DVI_GRAPHICS_MAX_WIDTH / scale;
      int fb_line = (scale == 1) ? line : (line >> 1);
      if (full_build) {
        buf[grp + 0] = ctrl_sync;
        buf[grp + 1] = fifo;
        buf[grp + 2] = count_of(hsync_cmd);
        buf[grp + 3] = (uintptr_t)hsync_cmd;
        buf[grp + 4] = (scale == 1) ? ctrl_text_pixel : ctrl_pixel;
        buf[grp + 5] = fifo;
        buf[grp + 6] = (scale == 1) ? (gw / sizeof(uint32_t)) : gw;
        buf[grp + 7] = (uintptr_t)&screenbuf.framebuffer[fb_line * gw];
      } else {
        buf[grp + 7] = (uintptr_t)&screenbuf.framebuffer[fb_line * gw];
      }
    }
    if (full_build) {
      buf[BATCH_SIZE * 8 + 0] = ctrl_stop;
      buf[BATCH_SIZE * 8 + 1] = 0;
      buf[BATCH_SIZE * 8 + 2] = 0;
      buf[BATCH_SIZE * 8 + 3] = 0;
    }
  }
}

void __scratch_x("") dma_irq_handler(void) {
  dma_hw->ints1 = 1u << DMACH_DATA;

  // Start the next pre-prepared descriptor buffer FIRST (time-critical).
  // Every cycle before this trigger eats into the blanking budget.
  int next_idx = cur_desc_idx ^ 1;
  dma_hw->ch[DMACH_CMD].al3_read_addr_trig =
      (uintptr_t)dma_scanline_buf[next_idx];
  int free_idx = cur_desc_idx;
  cur_desc_idx = next_idx;

  // cur_line = first line of the batch we just triggered
  cur_line = buf_first_line[next_idx];

#ifdef DVI_DIAGNOSTICS
  // FIFO diagnostics (non-critical, after trigger)
  uint32_t fifo_stat = hstx_fifo_hw->stat;
  uint32_t fifo_level = fifo_stat & 0xFF;
  if (fifo_level < dvi_fifo_min_level)
    dvi_fifo_min_level = fifo_level;
  if (fifo_stat & (1u << 9)) {
    dvi_fifo_empty_count++;
    uint32_t idx = dvi_fifo_empty_log_idx;
    if (idx < FIFO_EMPTY_LOG_SIZE)
      dvi_fifo_empty_log[idx] = cur_line;
    dvi_fifo_empty_log_idx = idx + 1;
  }

  // IRQ-to-IRQ interval measurement
  uint32_t now = *DWT_CYCCNT;
  uint32_t interval = now - last_irq_timestamp;
  last_irq_timestamp = now;
  if (interval < dvi_irq_interval_min)
    dvi_irq_interval_min = interval;
  if (interval > dvi_irq_interval_max)
    dvi_irq_interval_max = interval;
#endif

  // Determine batch size: BATCH_SIZE for active lines, 1 for blanking.
  int batch_size = (cur_line < MODE_V_ACTIVE_LINES) ? BATCH_SIZE : 1;

  // Signal VBlank at the first non-active line so Core 0 gets the entire
  // blanking interval (~360K cycles) for pre-render work.
  if (cur_line == MODE_V_ACTIVE_LINES) {
    frame_count++;
    // Swap text VRAM double-buffer pointers if Core 0 requested it.
    if (swap_pending) {
      render_vram = write_vram;
      render_row_has_wide = write_row_has_wide;
      render_scroll_offset = write_scroll_offset;
      swap_pending = false;
    }
    __asm volatile("sev"); // wake Core 0 WFE
  }

  // Apply mode switch during VSync pulse, when HSTX FIFO is guaranteed
  // empty (only sync words, no pixel data to misinterpret).
  if (cur_line == MODE_V_ACTIVE_LINES + MODE_V_FRONT_PORCH) {
    int pending = next_mode;
    if (pending >= 0) {
      next_mode = -1;
      active_mode = (dvi_mode_t)pending;
    }

    // Apply pending graphics scale change
    int pending_scale = next_graphics_scale;
    if (pending_scale > 0) {
      next_graphics_scale = -1;
    }

    // Reconfigure HSTX ENC_N_SHIFTS based on mode and scale.
    // Text mode and 640x480 graphics: 4 shifts (4 pixels per 32-bit word).
    // 320x240 graphics: 2 shifts (byte-lane replication for 2x scaling).
    {
      int n_shifts =
          (active_mode == DVI_MODE_GRAPHICS && graphics_scale == 2) ? 2 : 4;
      hstx_ctrl_hw->expand_shift =
          n_shifts << HSTX_CTRL_EXPAND_SHIFT_ENC_N_SHIFTS_LSB |
          8 << HSTX_CTRL_EXPAND_SHIFT_ENC_SHIFT_LSB |
          1 << HSTX_CTRL_EXPAND_SHIFT_RAW_N_SHIFTS_LSB |
          0 << HSTX_CTRL_EXPAND_SHIFT_RAW_SHIFT_LSB;
    }
  }

  // Build descriptors for the batch after the one we just triggered.
  int build_start = cur_line + batch_size;
  if (build_start >= MODE_V_TOTAL_LINES)
    build_start -= MODE_V_TOTAL_LINES;

#ifdef DVI_DIAGNOSTICS
  uint32_t cyc0 = *DWT_CYCCNT;
#endif
  prepare_batch_dma(dma_scanline_buf[free_idx], build_start);
  buf_first_line[free_idx] = build_start;
#ifdef DVI_DIAGNOSTICS
  uint32_t elapsed = *DWT_CYCCNT - cyc0;
  if (elapsed > dvi_irq_max_cycles)
    dvi_irq_max_cycles = elapsed;
#endif
}

// ----------------------------------------------------------------------------
// Public API

void dvi_start_mode(dvi_mode_t mode) {
  active_mode = mode;

#ifdef DVI_DIAGNOSTICS
  // Enable DWT cycle counter for IRQ timing measurement
  *DEMCR |= (1u << 24); // TRCENA: enable DWT
  *DWT_CTRL |= 1u;      // CYCCNTENA: enable cycle counter
  *DWT_CYCCNT = 0;

  // Enable bus fabric performance counters for SRAM9 (SCRATCH_Y) monitoring
  bus_ctrl_hw->perfctr_en = 1;
  bus_ctrl_hw->counter[0].sel = 0x12; // SRAM9_ACCESS_CONTESTED
  bus_ctrl_hw->counter[0].value = 0;
  bus_ctrl_hw->counter[1].sel = 0x13; // SRAM9_ACCESS
  bus_ctrl_hw->counter[1].value = 0;
#endif

  // Configure HSTX's TMDS encoder for RGB332
  hstx_ctrl_hw->expand_tmds = 2 << HSTX_CTRL_EXPAND_TMDS_L2_NBITS_LSB |
                              0 << HSTX_CTRL_EXPAND_TMDS_L2_ROT_LSB |
                              2 << HSTX_CTRL_EXPAND_TMDS_L1_NBITS_LSB |
                              29 << HSTX_CTRL_EXPAND_TMDS_L1_ROT_LSB |
                              1 << HSTX_CTRL_EXPAND_TMDS_L0_NBITS_LSB |
                              26 << HSTX_CTRL_EXPAND_TMDS_L0_ROT_LSB;

  // Configure HSTX ENC_N_SHIFTS based on mode and runtime scale.
  {
    int n_shifts = (mode == DVI_MODE_GRAPHICS && graphics_scale == 2) ? 2 : 4;
    hstx_ctrl_hw->expand_shift =
        n_shifts << HSTX_CTRL_EXPAND_SHIFT_ENC_N_SHIFTS_LSB |
        8 << HSTX_CTRL_EXPAND_SHIFT_ENC_SHIFT_LSB |
        1 << HSTX_CTRL_EXPAND_SHIFT_RAW_N_SHIFTS_LSB |
        0 << HSTX_CTRL_EXPAND_SHIFT_RAW_SHIFT_LSB;
  }

  // Serial output: CLKDIV=5, N_SHIFTS=5, SHIFT=2.
  hstx_ctrl_hw->csr = 0;
  hstx_ctrl_hw->csr = HSTX_CTRL_CSR_EXPAND_EN_BITS |
                      5u << HSTX_CTRL_CSR_CLKDIV_LSB |
                      5u << HSTX_CTRL_CSR_N_SHIFTS_LSB |
                      2u << HSTX_CTRL_CSR_SHIFT_LSB | HSTX_CTRL_CSR_EN_BITS;

  // HSTX outputs 0 through 7 appear on GPIO 12 through 19.
  hstx_ctrl_hw->bit[0] = HSTX_CTRL_BIT0_CLK_BITS | HSTX_CTRL_BIT0_INV_BITS;
  hstx_ctrl_hw->bit[1] = HSTX_CTRL_BIT0_CLK_BITS;
  for (uint lane = 0; lane < 3; ++lane) {
    int bit = 2 + lane * 2;
    uint32_t sel = (lane * 10) << HSTX_CTRL_BIT0_SEL_P_LSB |
                   (lane * 10 + 1) << HSTX_CTRL_BIT0_SEL_N_LSB;
    hstx_ctrl_hw->bit[bit] = sel | HSTX_CTRL_BIT0_INV_BITS;
    hstx_ctrl_hw->bit[bit + 1] = sel;
  }

  for (int i = 12; i <= 19; ++i) {
    gpio_set_function(i, GPIO_FUNC_HSTX);
    gpio_set_drive_strength(i, GPIO_DRIVE_STRENGTH_8MA);
  }

  // Build DMA control words for scanline descriptors.
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

  // CTRL_TEXT_PIXEL: text mode pixel data (SIZE_32, DREQ_HSTX) for native 640
  channel_config_set_transfer_data_size(&c, DMA_SIZE_32);
  ctrl_text_pixel = channel_config_get_ctrl_value(&c);

  // CTRL_STOP: NULL stop marker (TREQ_FORCE, triggers IRQ via null trigger)
  channel_config_set_transfer_data_size(&c, DMA_SIZE_32);
  channel_config_set_dreq(&c, DREQ_FORCE);
  ctrl_stop = channel_config_get_ctrl_value(&c);

  init_font_byte_mask();

  // Initialize text mode state (both VRAM buffers)
  memcpy(text_palette, default_palette, sizeof(default_palette));
  update_palette32();
  memset(text_vram_a, 0, sizeof(text_vram_a));
  memset(text_vram_b, 0, sizeof(text_vram_b));
  memset(row_has_wide_a, 0, sizeof(row_has_wide_a));
  memset(row_has_wide_b, 0, sizeof(row_has_wide_b));
  write_vram = text_vram_a;
  render_vram = text_vram_a;
  write_row_has_wide = row_has_wide_a;
  render_row_has_wide = row_has_wide_a;
  write_scroll_offset = 0;
  render_scroll_offset = 0;
  memset(screenbuf.glyph_bitmap, 0, GLYPH_BITMAP_SIZE);
  swap_pending = false;
  memset(line_buf, 0, sizeof(line_buf));
  line_buf_next = 0;

  // Prepare initial batch buffers: batch [0..3] and batch [4..7]
  prepare_batch_dma(dma_scanline_buf[0], 0);
  buf_first_line[0] = 0;
  prepare_batch_dma(dma_scanline_buf[1], BATCH_SIZE);
  buf_first_line[1] = BATCH_SIZE;

  // Configure CMD channel
  c = dma_channel_get_default_config(DMACH_CMD);
  channel_config_set_chain_to(&c, DMACH_CMD);
  channel_config_set_dreq(&c, DREQ_FORCE);
  channel_config_set_ring(&c, true, 4); // Ring on write, 2^4 = 16 bytes
  channel_config_set_high_priority(&c, true);
  channel_config_set_write_increment(&c, true);
  dma_channel_configure(DMACH_CMD, &c, &dma_hw->ch[DMACH_DATA].al3_ctrl,
                        dma_scanline_buf[0], 4, false);

  // DATA channel IRQ: fires once per scanline at NULL stop marker.
  dma_hw->ints1 = 1u << DMACH_DATA;
  dma_hw->inte1 = 1u << DMACH_DATA;
  irq_set_exclusive_handler(DMA_IRQ_1, dma_irq_handler);
  irq_set_priority(DMA_IRQ_1, 0x00);
  irq_set_enabled(DMA_IRQ_1, true);

  bus_ctrl_hw->priority =
      BUSCTRL_BUS_PRIORITY_DMA_W_BITS | BUSCTRL_BUS_PRIORITY_DMA_R_BITS;

  // Start by triggering CMD to process the first scanline
  dma_hw->ch[DMACH_CMD].al3_read_addr_trig = (uintptr_t)dma_scanline_buf[0];
}

void dvi_set_mode(dvi_mode_t mode) { next_mode = (int)mode; }

void dvi_set_blanking(bool enable) { dvi_blanking = enable; }

int dvi_graphics_get_width(void) {
  return DVI_GRAPHICS_MAX_WIDTH / graphics_scale;
}
int dvi_graphics_get_height(void) {
  return DVI_GRAPHICS_MAX_HEIGHT / graphics_scale;
}

void dvi_set_graphics_scale(int scale) {
  if (scale != 1 && scale != 2)
    return;
  graphics_scale = scale;
  next_graphics_scale = scale;
}

uint8_t *dvi_get_framebuffer(void) {
  graphics_dirty = true;
  if (graphics_scale == 2)
    return screenbuf.framebuffer +
           (DVI_GRAPHICS_HALF_SIZE); // SRAM back buffer (second half)
  return back_framebuf ? back_framebuf : screenbuf.framebuffer;
}

void dvi_graphics_set_back_buffer(uint8_t *back_buffer) {
  back_framebuf = back_buffer;
}

void dvi_graphics_commit(void) {
  dvi_wait_vsync();
  if (!graphics_dirty)
    return;
  int gw = DVI_GRAPHICS_MAX_WIDTH / graphics_scale;
  int gh = DVI_GRAPHICS_MAX_HEIGHT / graphics_scale;
  if (graphics_scale == 2) {
    memcpy(screenbuf.framebuffer, screenbuf.framebuffer + (DVI_GRAPHICS_HALF_SIZE), gw * gh);
  } else if (back_framebuf) {
    memcpy(screenbuf.framebuffer, back_framebuf, gw * gh);
  }
  graphics_dirty = false;
}

uint32_t dvi_get_frame_count(void) { return frame_count; }

uint32_t dvi_get_fifo_empty_count(void) { return dvi_fifo_empty_count; }

uint32_t dvi_get_hstx_csr(void) { return hstx_ctrl_hw->csr; }

uint32_t dvi_get_hsync_cmd0(void) { return hsync_cmd[0]; }

uint32_t dvi_get_fifo_stat(void) { return hstx_fifo_hw->stat; }

void dvi_read_bus_counters(uint32_t *contested, uint32_t *access) {
  *contested = bus_ctrl_hw->counter[0].value;
  *access = bus_ctrl_hw->counter[1].value;
  // Clear after read
  bus_ctrl_hw->counter[0].value = 0;
  bus_ctrl_hw->counter[1].value = 0;
}

void dvi_wait_vsync(void) {
  uint32_t last = frame_count;
  while (frame_count == last) {
    asm volatile("wfe" ::: "memory");
  }
}

// ----------------------------------------------------------------------------
// Text mode API

dvi_text_cell_t *dvi_get_text_vram(void) { return write_vram; }

int dvi_text_get_cols(void) { return text_cols; }

int dvi_text_get_rows(void) { return text_rows; }

void dvi_text_set_font(const dvi_font_t *font) {
  text_font = font;
  text_cols = MODE_H_ACTIVE_PIXELS / font->glyph_width;
  int content_height = MODE_V_ACTIVE_LINES;
  text_rows = (content_height + font->glyph_height - 1) / font->glyph_height;
  if (text_cols > DVI_TEXT_MAX_COLS)
    text_cols = DVI_TEXT_MAX_COLS;
  if (text_rows > DVI_TEXT_MAX_ROWS)
    text_rows = DVI_TEXT_MAX_ROWS;

  // Build row-major SRAM cache (regular region 0-255) from column-major font.
  if (font->glyph_height <= TEXT_GLYPH_HEIGHT_12WIDE) {
    const uint8_t *src = font->bitmap;
    int first = font->first_char;
    int num = font->num_chars;
    int gh = font->glyph_height;
    memset(narrow_row_cache, 0, sizeof(narrow_row_cache));
    for (int ch = 0; ch < num; ch++) {
      for (int y = 0; y < gh; y++) {
        narrow_row_cache[y * NARROW_CACHE_STRIDE + (first + ch)] =
            src[ch * gh + y];
      }
    }
  }
}

void dvi_text_set_wide_font(const dvi_font_t *font) { text_wide_font = font; }

void dvi_text_set_bold_font(const dvi_font_t *font) {
  if (font && font->glyph_height <= TEXT_GLYPH_HEIGHT_12WIDE) {
    const uint8_t *src = font->bitmap;
    int first = font->first_char;
    int num = font->num_chars;
    int gh = font->glyph_height;
    // Build bold region (offset 256-511) of the 512-stride cache.
    for (int y = 0; y < gh; y++)
      memset(&narrow_row_cache[y * NARROW_CACHE_STRIDE + 256], 0, 256);
    for (int ch = 0; ch < num; ch++) {
      for (int y = 0; y < gh; y++) {
        narrow_row_cache[y * NARROW_CACHE_STRIDE + 256 + (first + ch)] =
            src[ch * gh + y];
      }
    }
  }
}

void dvi_text_set_palette(const uint8_t palette[16]) {
  memcpy(text_palette, palette, 16);
  update_palette32();
}

void dvi_text_put_char(int col, int row, char ch, uint8_t attr) {
  if (col < 0 || col >= text_cols || row < 0 || row >= text_rows)
    return;
  int phys = physical_row(row, write_scroll_offset);
  dvi_text_cell_t *c = &write_vram[phys * text_cols + col];
  c->ch = (uint8_t)ch;
  c->attr = attr;
  c->flags = 0;
}

void dvi_text_put_char_bold(int col, int row, char ch, uint8_t attr) {
  if (col < 0 || col >= text_cols || row < 0 || row >= text_rows)
    return;
  int phys = physical_row(row, write_scroll_offset);
  dvi_text_cell_t *c = &write_vram[phys * text_cols + col];
  c->ch = (uint8_t)ch | 0x100; // bit 8 = bold indicator for 512-stride cache
  c->attr = attr;
  c->flags = DVI_CELL_FLAG_BOLD;
}

void dvi_text_put_wide_char(int col, int row, uint16_t ch, uint8_t attr) {
  if (col < 0 || col + 1 >= text_cols || row < 0 || row >= text_rows)
    return;
  int phys = physical_row(row, write_scroll_offset);
  dvi_text_cell_t *left = &write_vram[phys * text_cols + col];
  dvi_text_cell_t *right = &write_vram[phys * text_cols + col + 1];
  left->ch = ch; // linear JIS index (used by write_line for re-rendering)
  left->attr = attr;
  left->flags = DVI_CELL_FLAG_WIDE_L;
  right->ch = 0;
  right->attr = attr;
  right->flags = DVI_CELL_FLAG_WIDE_R;
  write_row_has_wide[phys] = 1;
  render_wide_glyph_at(col, phys, ch, text_wide_font, false);
}

void dvi_text_put_wide_char_bold(int col, int row, uint16_t ch, uint8_t attr) {
  if (col < 0 || col + 1 >= text_cols || row < 0 || row >= text_rows)
    return;
  int phys = physical_row(row, write_scroll_offset);
  dvi_text_cell_t *left = &write_vram[phys * text_cols + col];
  dvi_text_cell_t *right = &write_vram[phys * text_cols + col + 1];
  left->ch = ch; // linear JIS index
  left->attr = attr;
  left->flags = DVI_CELL_FLAG_WIDE_L | DVI_CELL_FLAG_BOLD;
  right->ch = 0;
  right->attr = attr;
  right->flags = DVI_CELL_FLAG_WIDE_R | DVI_CELL_FLAG_BOLD;
  write_row_has_wide[phys] = 1;
  render_wide_glyph_at(col, phys, ch, text_wide_font, true);
}

// Decode one UTF-8 character from str, store codepoint in *cp.
// Returns pointer to next character, or NULL on invalid sequence.
static const char *utf8_decode(const char *str, uint32_t *cp) {
  uint8_t b = (uint8_t)*str;
  if (b < 0x80) {
    *cp = b;
    return str + 1;
  } else if ((b & 0xE0) == 0xC0) {
    *cp = (b & 0x1F) << 6 | ((uint8_t)str[1] & 0x3F);
    return str + 2;
  } else if ((b & 0xF0) == 0xE0) {
    *cp = (b & 0x0F) << 12 | ((uint8_t)str[1] & 0x3F) << 6 |
          ((uint8_t)str[2] & 0x3F);
    return str + 3;
  } else if ((b & 0xF8) == 0xF0) {
    *cp = (b & 0x07) << 18 | ((uint8_t)str[1] & 0x3F) << 12 |
          ((uint8_t)str[2] & 0x3F) << 6 | ((uint8_t)str[3] & 0x3F);
    return str + 4;
  }
  *cp = '?';
  return str + 1;
}

// Wrapper for shared uni2jis_lookup (defined in uni2jis_table.h).
static inline uint16_t unicode_to_jis(uint32_t cp) {
  return uni2jis_lookup(cp);
}

void dvi_text_put_string(int col, int row, const char *str, uint8_t attr) {
  int start_col = col;
  while (*str && row < text_rows) {
    uint32_t cp;
    str = utf8_decode(str, &cp);

    if (cp == '\n') {
      col = start_col;
      row++;
      continue;
    }

    if (cp < 0x80) {
      if (col >= text_cols) {
        col = start_col;
        row++;
        if (row >= text_rows)
          break;
      }
      dvi_text_put_char(col, row, (char)cp, attr);
      col++;
    } else {
      uint16_t jis = unicode_to_jis(cp);
      if (jis) {
        if (col + 1 >= text_cols) {
          col = start_col;
          row++;
          if (row >= text_rows)
            break;
        }
        dvi_text_put_wide_char(col, row, dvi_jis_to_linear(jis), attr);
        col += 2;
      } else {
        if (col >= text_cols) {
          col = start_col;
          row++;
          if (row >= text_rows)
            break;
        }
        dvi_text_put_char(col, row, '?', attr);
        col++;
      }
    }
  }
}

void dvi_text_put_string_bold(int col, int row, const char *str, uint8_t attr) {
  int start_col = col;
  while (*str && row < text_rows) {
    uint32_t cp;
    str = utf8_decode(str, &cp);

    if (cp == '\n') {
      col = start_col;
      row++;
      continue;
    }

    if (cp < 0x80) {
      if (col >= text_cols) {
        col = start_col;
        row++;
        if (row >= text_rows)
          break;
      }
      dvi_text_put_char_bold(col, row, (char)cp, attr);
      col++;
    } else {
      uint16_t jis = unicode_to_jis(cp);
      if (jis) {
        if (col + 1 >= text_cols) {
          col = start_col;
          row++;
          if (row >= text_rows)
            break;
        }
        dvi_text_put_wide_char_bold(col, row, dvi_jis_to_linear(jis), attr);
        col += 2;
      } else {
        if (col >= text_cols) {
          col = start_col;
          row++;
          if (row >= text_rows)
            break;
        }
        dvi_text_put_char_bold(col, row, '?', attr);
        col++;
      }
    }
  }
}

void dvi_text_clear(uint8_t attr) {
  for (int i = 0; i < text_rows * text_cols; i++) {
    write_vram[i].ch = ' ';
    write_vram[i].attr = attr;
    write_vram[i].flags = 0;
  }
  memset(write_row_has_wide, 0, text_rows);
  memset(screenbuf.glyph_bitmap, 0, GLYPH_BITMAP_SIZE);
  write_scroll_offset = 0;
}

// Clear a physical row (used internally by scroll).
static void clear_physical_line(int phys, uint8_t attr) {
  dvi_text_cell_t *line = &write_vram[phys * text_cols];
  for (int i = 0; i < text_cols; i++) {
    line[i].ch = ' ';
    line[i].attr = attr;
    line[i].flags = 0;
  }
  write_row_has_wide[phys] = 0;
  // Clear glyph bitmap for this physical row
  memset(screenbuf.glyph_bitmap + phys * TEXT_GLYPH_HEIGHT_12WIDE * GLYPH_BITMAP_STRIDE,
         0, TEXT_GLYPH_HEIGHT_12WIDE * GLYPH_BITMAP_STRIDE);
}

void dvi_text_clear_line(int row, uint8_t attr) {
  if (row < 0 || row >= text_rows)
    return;
  int phys = physical_row(row, write_scroll_offset);
  clear_physical_line(phys, attr);
}

void dvi_text_set_palette_entry(int index, uint8_t color) {
  if (index < 0 || index >= 16)
    return;
  text_palette[index] = color;
  update_palette32();
}

uint8_t dvi_text_get_palette_entry(int index) {
  if (index < 0 || index >= 16)
    return 0;
  return text_palette[index];
}

// ----------------------------------------------------------------------------
// Double-buffer commit

void dvi_text_commit(void) {
  swap_pending = true;
  uint32_t last = frame_count;
  while (frame_count == last) {
    asm volatile("wfe" ::: "memory");
  }
  // Flip write buffer to the other array
  if (write_vram == text_vram_a) {
    write_vram = text_vram_b;
    write_row_has_wide = row_has_wide_b;
  } else {
    write_vram = text_vram_a;
    write_row_has_wide = row_has_wide_a;
  }
  // Copy front buffer state to new back buffer
  write_scroll_offset = render_scroll_offset;
  memcpy(write_vram, render_vram,
         text_rows * text_cols * sizeof(dvi_text_cell_t));
  memcpy(write_row_has_wide, render_row_has_wide, text_rows);
}

// ----------------------------------------------------------------------------
// Extended text operations

void dvi_text_scroll_up(int lines, uint8_t fill_attr) {
  if (lines <= 0)
    return;
  if (lines >= text_rows) {
    dvi_text_clear(fill_attr);
    return;
  }
  // Ring buffer: advance offset and clear the vacated rows.
  for (int i = 0; i < lines; i++) {
    int phys = physical_row(0, write_scroll_offset);
    clear_physical_line(phys, fill_attr);
    write_scroll_offset++;
    if (write_scroll_offset >= text_rows)
      write_scroll_offset -= text_rows;
  }
}

void dvi_text_scroll_down(int lines, uint8_t fill_attr) {
  if (lines <= 0)
    return;
  if (lines >= text_rows) {
    dvi_text_clear(fill_attr);
    return;
  }
  // Ring buffer: retreat offset and clear the vacated rows.
  for (int i = 0; i < lines; i++) {
    write_scroll_offset--;
    if (write_scroll_offset < 0)
      write_scroll_offset += text_rows;
    int phys = physical_row(0, write_scroll_offset);
    clear_physical_line(phys, fill_attr);
  }
}

void dvi_text_clear_range(int col, int row, int width, uint8_t attr) {
  if (row < 0 || row >= text_rows)
    return;
  if (col < 0) {
    width += col;
    col = 0;
  }
  if (col + width > text_cols)
    width = text_cols - col;
  if (width <= 0)
    return;
  int phys = physical_row(row, write_scroll_offset);
  dvi_text_cell_t *line = &write_vram[phys * text_cols + col];
  for (int i = 0; i < width; i++) {
    line[i].ch = ' ';
    line[i].attr = attr;
    line[i].flags = 0;
  }
}

uint8_t dvi_text_get_attr(int col, int row) {
  if (col < 0 || col >= text_cols || row < 0 || row >= text_rows)
    return 0;
  int phys = physical_row(row, write_scroll_offset);
  return write_vram[phys * text_cols + col].attr;
}

void dvi_text_set_attr(int col, int row, uint8_t attr) {
  if (col < 0 || col >= text_cols || row < 0 || row >= text_rows)
    return;
  int phys = physical_row(row, write_scroll_offset);
  write_vram[phys * text_cols + col].attr = attr;
}

void dvi_text_read_line(int row, dvi_text_cell_t *dst) {
  if (row < 0 || row >= text_rows || !dst)
    return;
  int phys = physical_row(row, write_scroll_offset);
  memcpy(dst, &write_vram[phys * text_cols],
         text_cols * sizeof(dvi_text_cell_t));
}

void dvi_text_write_line(int row, const dvi_text_cell_t *src) {
  if (row < 0 || row >= text_rows || !src)
    return;
  int phys = physical_row(row, write_scroll_offset);
  memcpy(&write_vram[phys * text_cols], src,
         text_cols * sizeof(dvi_text_cell_t));
  // Re-render wide glyphs from cell data into per-position bitmap.
  uint8_t has_wide = 0;
  for (int col = 0; col < text_cols; col++) {
    if (src[col].flags & DVI_CELL_FLAG_WIDE_L) {
      bool bold = src[col].flags & DVI_CELL_FLAG_BOLD;
      render_wide_glyph_at(col, phys, src[col].ch, text_wide_font, bold);
      has_wide = 1;
    }
  }
  write_row_has_wide[phys] = has_wide;
}
