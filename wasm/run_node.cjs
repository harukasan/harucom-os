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
 * Three gates, all exit non-zero on failure so `rake wasm:test` is usable in CI:
 *   1. harucom_init() must succeed (VM + MEMFS rootfs + task scheduler).
 *   2. The DVI text core must have rendered the C bring-up banner into the
 *      framebuffer (the same pixels the browser canvas blits), checked by
 *      sampling palette colors and the full-width glyph region.
 *   3. The Ruby boot task must actually run (rootfs deployed, /system.rb read),
 *      checked against the captured stdout/stderr. harucom_init returning 0 only
 *      means the task compiled; without this a broken rootfs deploy or a boot
 *      task that raises at runtime would still pass gates 1 and 2 (the banner is
 *      drawn from C, independent of Ruby).
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

// Capture every line the wasm prints (fd 1 / 2 via the posix hal_write) while
// still echoing it, so gate 3 can assert against the boot task's output.
const output = [];
const record = (stream, s) => {
  output.push(s);
  stream.write(s + "\n");
};

function runChecks(checks, note) {
  let ok = true;
  for (const [name, pass] of checks) {
    process.stdout.write(`  [${pass ? "PASS" : "FAIL"}] ${name}\n`);
    if (!pass) ok = false;
  }
  if (note) process.stdout.write(`  (${note})\n`);
  return ok;
}

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
  return runChecks(
    checks,
    `non-bg=${nonbg}, distinct colors=${colors.size}, wideRegionCyan=${wideRegionCyan}`
  );
}

// Verify the Ruby boot task ran by checking its printed output. The bootstrap
// (mrbgems/harucom-os-wasm/src/harucom_wasm.c) prints a banner, reads
// /system.rb back from MEMFS, and prints its byte size; a failure prints
// "boot error:". deploy_rootfs() logs the file count to stderr.
function verifyBoot() {
  const text = output.join("\n");
  const checks = [
    ["rootfs deployed to MEMFS", /rootfs: deployed \d+ files/.test(text)],
    ["boot task started", text.includes("Harucom OS (wasm) booting")],
    ["/system.rb read back from MEMFS", /system\.rb: \d+ bytes/.test(text)],
    ["no boot error raised", !text.includes("boot error:")],
  ];
  return runChecks(checks, null);
}

createHarucomModule({
  print: (s) => record(process.stdout, s),
  printErr: (s) => record(process.stderr, s),
})
  .then((Module) => {
    const rc = Module._harucom_init();
    process.stdout.write(`\n[harucom_init rc=${rc}]\n`);
    if (rc !== 0) {
      process.stderr.write("harucom_init failed\n");
      process.exit(1);
    }

    process.stdout.write("[DVI render verification]\n");
    const renderOk = verifyRender(Module);

    // The boot task's puts run while the scheduler advances, so drive it first,
    // then check its output.
    for (let i = 0; i < 5000; i++) {
      Module._mrb_tick_wasm();
      Module._mrb_run_step();
    }

    process.stdout.write("[Ruby boot verification]\n");
    const bootOk = verifyBoot();

    if (!renderOk || !bootOk) {
      process.stderr.write("smoke test failed\n");
      process.exit(1);
    }
    process.stdout.write("[done driving scheduler]\n");
    process.exit(0);
  })
  .catch((e) => {
    process.stderr.write(`harness error: ${e}\n`);
    process.exit(1);
  });
