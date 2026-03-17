#ifndef DVI_DEFINED_H_
#define DVI_DEFINED_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DVI_FRAME_WIDTH  640
#define DVI_FRAME_HEIGHT 360

uint8_t *dvi_get_framebuffer(void);
uint32_t dvi_get_frame_count(void);
void dvi_wait_vsync(void);

#ifdef __cplusplus
}
#endif

#endif /* DVI_DEFINED_H_ */
