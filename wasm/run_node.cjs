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
 *   2. Booting /system.rb must run the full userland: deploy rootfs, require the
 *      console / IME / line editor / keyboard / IRB libraries, and reach the IRB
 *      banner. The Console mirrors its output to STDOUT (fd 1), so the banner is
 *      captured here even though it is really painted on the DVI text surface.
 *   3. The Console must have rendered into the framebuffer (the pixels the
 *      browser canvas blits), checked by sampling for non-background pixels.
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
// still echoing it, so the boot gate can assert against the userland's output.
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

// Drive the cooperative scheduler the way the browser run loop does: tick the
// clock (so sleep_ms / DVI.wait_vsync tasks wake) then run one step. The boot
// task loads /system.rb in a sandbox, which requires the userland libraries and
// finally starts IRB; stop early once the IRB banner has been printed.
function driveUntilBooted(Module, marker, maxSteps) {
  for (let i = 0; i < maxSteps; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
    if (i % 64 === 0 && output.join("\n").includes(marker)) return i + 1;
  }
  return maxSteps;
}

// Verify the userland actually booted by checking the IRB banner reached STDOUT
// (Console mirrors DVI output to the original STDOUT). Reaching the banner means
// every require in system.rb resolved and IRB started; a failed require or a
// raised exception would stop before it.
function verifyBoot(steps) {
  const text = output.join("\n");
  const checks = [
    ["rootfs deployed to MEMFS", /rootfs: deployed \d+ files/.test(text)],
    ["IRB banner reached (system.rb booted)", text.includes("Powered by PicoRuby")],
    ["banner author line printed", text.includes("Shunsuke Michii")],
  ];
  return runChecks(checks, `drove ${steps} scheduler steps`);
}

// Verify the Console rendered into the framebuffer (the same pixels the browser
// canvas blits). The banner is drawn on the DVI text surface and committed, so
// after boot the framebuffer holds non-background pixels.
function verifyRender(Module) {
  const W = Module._harucom_dvi_width();
  const H = Module._harucom_dvi_height();
  const fb = Module._harucom_dvi_framebuffer();
  const px = Module.HEAPU8.subarray(fb, fb + W * H);

  const BG = 0x00; // palette[0], default background (see default_palette[])
  let nonbg = 0;
  const colors = new Set();
  for (let i = 0; i < px.length; i++) {
    if (px[i] !== BG) nonbg++;
    colors.add(px[i]);
  }

  const checks = [
    ["framebuffer is 640x480", W === 640 && H === 480],
    ["console rendered (non-background pixels)", nonbg > 500],
    ["frame committed at least once", Module._harucom_dvi_frame_count() > 0],
  ];
  return runChecks(checks, `non-bg=${nonbg}, distinct colors=${colors.size}`);
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

    const steps = driveUntilBooted(Module, "Powered by PicoRuby", 200000);

    process.stdout.write("[Ruby boot verification]\n");
    const bootOk = verifyBoot(steps);

    process.stdout.write("[DVI render verification]\n");
    const renderOk = verifyRender(Module);

    if (!bootOk || !renderOk) {
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
