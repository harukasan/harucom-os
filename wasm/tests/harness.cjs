// Shared harness for the wasm smoke tests.
//
// boot() creates one wasm VM, inits it (VM + MEMFS rootfs + scheduler), drives
// the cooperative scheduler until /system.rb reaches the IRB banner, and returns
// the Module plus input helpers bound to it. Each *.test.cjs file calls boot() in
// its before(), so the files are independent (node --test runs each in its own
// process; a fresh boot per file is cheap). It lives outside the test glob
// (named harness.cjs in tests/, not *.test.cjs) so the runner does not run it.
//
// The build is based on the picoruby-wasm gem, whose JS interop init requires a
// DOM (window/document); jsdom provides a real one so this exercises the same gem
// init the browser does. The real target is the browser (rake wasm:server); this
// harness is for headless smoke testing.
const assert = require("node:assert/strict");
const { JSDOM } = require("jsdom");

// Install the jsdom globals once, before the emscripten module is required (it
// probes window/document at load time).
let domReady = false;
function setupDom() {
  if (domReady) return;
  const dom = new JSDOM(
    '<!DOCTYPE html><canvas id="screen" width="640" height="480"></canvas>' +
    '<div id="app"></div>', // funicular mount point (mirrors the browser page)
    { pretendToBeVisual: true }
  );
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  globalThis.navigator = dom.window.navigator;
  // picoruby-wasm classifies a JS value as JS::Element via `instanceof Document
  // / Element / Event / ...` against the global constructors. A real browser has
  // these globally; under Node only jsdom has them (on dom.window), so expose the
  // ones the classifier checks or the document reads back as a plain JS::Object
  // and JS.document raises "Document object is not available".
  for (const name of ["Document", "Element", "Event", "Node", "NodeList", "HTMLCollection"]) {
    globalThis[name] = dom.window[name];
  }
  domReady = true;
}

const ENTER = [[0, 0x28]];

// Map a printable ASCII char to [modifier, HID usage] on the US layout, so a
// whole string can be typed through the keyboard pipeline. Mirrors
// picoruby-keyboard-input's LAYOUT_US_NORMAL / LAYOUT_US_SHIFTED.
function hidForChar(ch) {
  const SH = 0x02; // left shift bit
  const c = ch.charCodeAt(0);
  if (ch >= "a" && ch <= "z") return [0, 0x04 + c - 97];
  if (ch >= "A" && ch <= "Z") return [SH, 0x04 + c - 65];
  if (ch >= "1" && ch <= "9") return [0, 0x1e + c - 49];
  if (ch === "0") return [0, 0x27];
  const M = {
    " ": [0, 0x2c], "-": [0, 0x2d], "_": [SH, 0x2d], "=": [0, 0x2e], "+": [SH, 0x2e],
    "[": [0, 0x2f], "]": [0, 0x30], "\\": [0, 0x31], ";": [0, 0x33], ":": [SH, 0x33],
    "'": [0, 0x34], '"': [SH, 0x34], ",": [0, 0x36], ".": [0, 0x37], "/": [0, 0x38],
    "<": [SH, 0x36], ">": [SH, 0x37],
    "?": [SH, 0x38], "(": [SH, 0x26], ")": [SH, 0x27], "&": [SH, 0x24], "*": [SH, 0x25],
    "!": [SH, 0x1e], "@": [SH, 0x1f], "#": [SH, 0x20], "$": [SH, 0x21], "%": [SH, 0x22],
  };
  if (M[ch]) return M[ch];
  throw new Error("no HID mapping for char " + JSON.stringify(ch));
}

// Boot a fresh VM and return { Module, output, printed, bootSteps, ...helpers }.
async function boot() {
  setupDom();
  const createHarucomModule = require("../../build/wasm/harucom.js");
  const output = []; // every line the wasm prints (fd 1 / 2 via posix hal_write)
  const Module = await createHarucomModule({
    print: (s) => output.push(s),
    printErr: (s) => output.push(s),
  });
  assert.equal(Module._harucom_init(), 0, "harucom_init (VM + MEMFS rootfs + scheduler)");

  // Match the browser entry (wasm/js/main.js): drop the emscripten-only dirs so
  // tests see the same filesystem root the board has. Shared ESM helper.
  const { pruneRuntimeDirs } = await import("../js/engine/fs.js");
  pruneRuntimeDirs(Module);

  const printed = () => output.join("\n");

  // Drive the cooperative scheduler the way the browser run loop does: tick the
  // clock (so sleep_ms / DVI.wait_vsync tasks wake) then run one step.
  function drive(steps) {
    for (let i = 0; i < steps; i++) {
      Module._mrb_tick_wasm();
      Module._mrb_run_step();
    }
  }

  // Drive until `marker` appears in the output (or maxSteps elapse); returns the
  // number of steps taken. Used to wait for the IRB banner and echoed results.
  function driveUntil(marker, maxSteps) {
    for (let i = 0; i < maxSteps; i++) {
      Module._mrb_tick_wasm();
      Module._mrb_run_step();
      if (i % 64 === 0 && printed().includes(marker)) return i + 1;
    }
    return maxSteps;
  }

  // Inject HID keystrokes the way the browser keydown/keyup handlers do: hold one
  // usage so the keyboard task polls the press, then clear it so it polls the
  // release. Held only briefly so the OS key repeat (400ms) never fires.
  function hidType(keys) {
    for (const [modifier, usage] of keys) {
      Module._harucom_kbd_set_state(modifier, usage, 0, 0, 0, 0, 0);
      drive(200);
      Module._harucom_kbd_set_state(0, 0, 0, 0, 0, 0, 0);
      drive(200);
    }
  }

  // Type a whole ASCII string through the keyboard pipeline (one key at a time).
  function typeString(str) {
    for (const ch of str) {
      const [mod, usage] = hidForChar(ch);
      Module._harucom_kbd_set_state(mod, usage, 0, 0, 0, 0, 0);
      drive(100);
      Module._harucom_kbd_set_state(0, 0, 0, 0, 0, 0, 0);
      drive(100);
    }
  }

  // Type a line into IRB (string + Enter) and drive until its result is echoed;
  // returns only the output produced since the line was typed.
  function evalInIRB(line, expect, maxSteps = 40000) {
    const start = output.length;
    typeString(line);
    hidType(ENTER);
    driveUntil(expect, maxSteps);
    return output.slice(start).join("\n");
  }

  const bootSteps = driveUntil("Powered by PicoRuby", 200000);
  return { Module, output, printed, bootSteps, drive, driveUntil, hidType, typeString, evalInIRB, ENTER };
}

module.exports = { boot };
