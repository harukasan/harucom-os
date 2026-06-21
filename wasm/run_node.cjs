/*
 * Headless smoke test of the Harucom OS wasm build under Node.
 *
 *   rake wasm:test   (or: node wasm/run_node.cjs)
 *
 * The build is based on the picoruby-wasm gem, whose JS interop init requires a
 * DOM (window/document). jsdom provides a real one so this exercises the same
 * gem init the browser does, rather than hand-rolled stubs. The real target is
 * the browser (rake wasm:server); this harness is for headless smoke testing.
 *
 * Two gates, both exit non-zero on failure so `rake wasm:test` is usable in CI:
 *   1. harucom_init() must succeed (VM + MEMFS rootfs + task scheduler).
 *   2. The DVI text core must have rendered the C bring-up banner into the
 *      framebuffer (the same pixels the browser canvas blits), checked by
 *      sampling palette colors and the full-width glyph region.
 */
const { JSDOM } = require("jsdom");

const dom = new JSDOM(
  '<!DOCTYPE html><canvas id="screen" width="640" height="480"></canvas>',
  { pretendToBeVisual: true }
);
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.navigator = dom.window.navigator;

const createHarucomModule = require("../build/wasm/harucom.js");

// Verify the framebuffer holds the C-drawn banner. The banner uses three
// palette colors so each row exercises a distinct attribute, and a row of
// full-width Japanese glyphs exercises the wide (12px) rendering path.
function verifyRender(Module) {
  const W = Module._harucom_dvi_width();
  const H = Module._harucom_dvi_height();
  const fb = Module._harucom_dvi_framebuffer();
  const px = Module.HEAPU8.subarray(fb, fb + W * H);

  // RGB332 palette values (see default_palette in src/dvi_text.c).
  const BG = 0x00, YELLOW = 0xFC, WHITE = 0xFF, CYAN = 0x1F;

  let nonbg = 0;
  const colors = new Set();
  for (let i = 0; i < px.length; i++) {
    if (px[i] !== BG) nonbg++;
    colors.add(px[i]);
  }

  // Line 5 (y 65..77) is "日本語表示 wide-glyph test" in cyan. The 5 full-width
  // glyphs span x 0..59; 5 narrow fallback '?' glyphs would only reach x 30, so
  // cyan pixels at x 30..59 confirm the wide glyphs actually rasterized.
  let wideRegionCyan = 0;
  for (let y = 65; y <= 77; y++)
    for (let x = 30; x < 60; x++)
      if (px[y * W + x] === CYAN) wideRegionCyan++;

  const checks = [
    ["framebuffer is 640x480", W === 640 && H === 480],
    ["banner rendered (non-background pixels)", nonbg > 500],
    ["yellow banner, palette 11 (attr 0xB0)", colors.has(YELLOW)],
    ["white text, palette 15 (attr 0xF0)", colors.has(WHITE)],
    ["cyan text, palette 6 (attr 0x60)", colors.has(CYAN)],
    ["full-width glyphs rasterized", wideRegionCyan > 10],
  ];

  let ok = true;
  for (const [name, pass] of checks) {
    process.stdout.write(`  [${pass ? "PASS" : "FAIL"}] ${name}\n`);
    if (!pass) ok = false;
  }
  process.stdout.write(
    `  (non-bg=${nonbg}, distinct colors=${colors.size}, wideRegionCyan=${wideRegionCyan})\n`
  );
  return ok;
}

createHarucomModule({
  // stdout / stderr come from the posix hal_write() (emscripten fd 1 / 2).
  print: (s) => process.stdout.write(s + "\n"),
  printErr: (s) => process.stderr.write(s + "\n"),
})
  .then((Module) => {
    const rc = Module._harucom_init();
    process.stdout.write(`\n[harucom_init rc=${rc}]\n`);
    if (rc !== 0) {
      process.stderr.write("harucom_init failed\n");
      process.exit(1);
    }

    process.stdout.write("[DVI render verification]\n");
    if (!verifyRender(Module)) {
      process.stderr.write("DVI render verification failed\n");
      process.exit(1);
    }

    for (let i = 0; i < 5000; i++) {
      Module._mrb_tick_wasm();
      Module._mrb_run_step();
    }
    process.stdout.write("[done driving scheduler]\n");
    process.exit(0);
  })
  .catch((e) => {
    process.stderr.write(`harness error: ${e}\n`);
    process.exit(1);
  });
