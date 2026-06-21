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
 * Exits non-zero if harucom_init() fails, so `rake wasm:test` is a usable gate.
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
