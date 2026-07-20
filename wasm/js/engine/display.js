// DVI framebuffer (RGB332) -> canvas blitter.
//
// The wasm framebuffer is a static C array of RGB332 bytes; createDisplay caches
// its address once (stable across memory growth) and blit() converts it into the
// canvas ImageData each call. Module.HEAPU8 is re-read every blit because the
// heap view can be replaced when wasm memory grows.

export function createDisplay(Module, canvas) {
  // RGB332 (bits 7-5 R, 4-2 G, 1-0 B) -> RGBA lookup. Stored as little-endian
  // Uint32 (0xAABBGGRR) so it can be written straight into the ImageData view.
  const rgb332 = new Uint32Array(256);
  for (let c = 0; c < 256; c++) {
    const r = Math.round(((c >> 5) & 7) * 255 / 7);
    const g = Math.round(((c >> 2) & 7) * 255 / 7);
    const b = Math.round((c & 3) * 255 / 3);
    rgb332[c] = (0xFF << 24) | (b << 16) | (g << 8) | r;
  }

  const width = Module._harucom_dvi_width();
  const height = Module._harucom_dvi_height();
  const fbPtr = Module._harucom_dvi_framebuffer();
  const ctx = canvas.getContext("2d");
  const image = ctx.createImageData(width, height);
  const pixels = new Uint32Array(image.data.buffer);

  function blit() {
    const fb = Module.HEAPU8;
    for (let i = 0; i < width * height; i++) pixels[i] = rgb332[fb[fbPtr + i]];
    ctx.putImageData(image, 0, 0);
  }

  return { blit };
}
