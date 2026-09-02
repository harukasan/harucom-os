/*
 * Browser (emscripten) dictionary location.
 *
 * On RP2350 the chip maps the dictionary image into the address space through
 * XIP, so the shared lookup code reads it in place. The browser has no XIP, so
 * this loads the emcc-embedded image (/dict.bin in MEMFS) into a heap buffer
 * once at boot and hands the shared code that address instead. The image is
 * position independent, so nothing else differs.
 *
 * The whole file is guarded by __EMSCRIPTEN__ (the wasm build is emcc),
 * matching ports/posix/dvi_wasm.c and ports/posix/usb_host_wasm.c. picoruby
 * auto-compiles ports/posix under POSIX while ports/rp2350 (pico-sdk) is
 * excluded.
 */

#ifdef __EMSCRIPTEN__

#include <stdio.h>
#include <stdlib.h>

#include <emscripten.h>

#include "dict_region.h"

/* NULL until dict_wasm_init() has loaded the image. The shared lookups treat
 * that as "no dictionary", which is how the board behaves with none flashed. */
static const uint8_t *dict_data = NULL;

const uint8_t *
dict_region_base(void)
{
  return dict_data;
}

/* Load the embedded HCDK image into a heap buffer once. Called from
 * harucom_init() at boot, before the userland runs. The buffer is never freed.
 * It lives for the page lifetime, like the other wasm port state. */
EMSCRIPTEN_KEEPALIVE
void
dict_wasm_init(void)
{
  FILE *f = fopen("/dict.bin", "rb");
  if (!f) {
    fprintf(stderr, "dict: /dict.bin not found in MEMFS\n");
    return;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *buf = (size > 0) ? (uint8_t *)malloc((size_t)size) : NULL;
  if (buf && fread(buf, 1, (size_t)size, f) == (size_t)size) {
    dict_data = buf;
  } else {
    free(buf);
    fprintf(stderr, "dict: failed to read /dict.bin (%ld bytes)\n", size);
  }
  fclose(f);
  fprintf(stderr, "dict: loaded %ld bytes, available=%d\n", size, dict_available());
}

#endif /* __EMSCRIPTEN__ */
