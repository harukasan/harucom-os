#ifndef DVI_DEFINED_H_
#define DVI_DEFINED_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Pixel mode framebuffer dimensions (320x240, 2x scaled to 640x480)
#define DVI_FRAME_WIDTH  320
#define DVI_FRAME_HEIGHT 240

// Text mode grid dimensions (12px font: 6px half-width, 13px glyph height)
#define DVI_TEXT_MAX_COLS 106
#define DVI_TEXT_MAX_ROWS 37

// Cell flags
#define DVI_CELL_FLAG_WIDE_L  0x01  // left half of a full-width character
#define DVI_CELL_FLAG_WIDE_R  0x02  // right half (continuation)
#define DVI_CELL_FLAG_BOLD    0x80  // render with bold font variant

typedef struct {
    uint16_t ch;   // character code (ASCII for half-width, linear JIS index for full-width)
    uint8_t attr;  // bits 7-4: fg palette index, bits 3-0: bg palette index
    uint8_t flags; // DVI_CELL_FLAG_*
} dvi_text_cell_t;

typedef enum {
    DVI_MODE_PIXEL,  // 320x240 RGB332, 2x scaled to 640x480
    DVI_MODE_TEXT,   // text VRAM, native 640x480
} dvi_mode_t;

// Font data structure (defined in dvi_font.h)
#include "dvi_font.h"

// Common API
uint8_t *dvi_get_framebuffer(void);
uint32_t dvi_get_frame_count(void);
void dvi_wait_vsync(void);

// Text mode API
dvi_text_cell_t *dvi_get_text_vram(void);
int dvi_text_get_cols(void);
int dvi_text_get_rows(void);
void dvi_text_set_font(const dvi_font_t *font);
void dvi_text_set_wide_font(const dvi_font_t *font);
void dvi_text_set_bold_font(const dvi_font_t *font);
void dvi_text_set_palette(const uint8_t palette[16]);
void dvi_text_put_char(int col, int row, char ch, uint8_t attr);
void dvi_text_put_char_bold(int col, int row, char ch, uint8_t attr);
void dvi_text_put_wide_char(int col, int row, uint16_t ch, uint8_t attr);
void dvi_text_put_wide_char_bold(int col, int row, uint16_t ch, uint8_t attr);
void dvi_text_put_string(int col, int row, const char *str, uint8_t attr);
void dvi_text_put_string_bold(int col, int row, const char *str, uint8_t attr);
void dvi_text_clear(uint8_t attr);

// Convert a JIS X 0208 code to a linear font index.
static inline uint16_t dvi_jis_to_linear(uint16_t jis_code) {
    int ku = (jis_code >> 8) - 0x20;
    int ten = (jis_code & 0xFF) - 0x20;
    return (uint16_t)((ku - 1) * 94 + (ten - 1));
}

#ifdef __cplusplus
}
#endif

#endif /* DVI_DEFINED_H_ */
