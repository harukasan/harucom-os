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

// Run the scheduler for a fixed number of steps, ticking the clock each step so
// sleeping/waiting tasks wake.
function drive(Module, steps) {
  for (let i = 0; i < steps; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
  }
}

// Inject HID keystrokes the way the browser keydown/keyup handlers do: set the
// report with one usage held so the keyboard task polls the press, then clear it
// so it polls the release. Held only briefly so the OS key repeat (400ms) never
// fires (board_millis is real wall-clock time).
function hidType(Module, keys) {
  for (const [modifier, usage] of keys) {
    Module._harucom_kbd_set_state(modifier, usage, 0, 0, 0, 0, 0);
    drive(Module, 200);
    Module._harucom_kbd_set_state(0, 0, 0, 0, 0, 0, 0);
    drive(Module, 200);
  }
}

// End-to-end keystroke test through the whole input pipeline (USB host stub ->
// Keyboard -> LineEditor -> IRB -> Sandbox eval): type "9-7" + Enter (all
// unshifted US keys) and confirm IRB echoes "=> 2". This exercises
// harucom_kbd_set_state and the reused keyboard/line-editor/IRB stack headlessly.
function verifyInput(Module) {
  hidType(Module, [[0, 0x26], [0, 0x2D], [0, 0x24], [0, 0x28]]); // 9 - 7 Enter
  for (let i = 0; i < 20000; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
    if (i % 64 === 0 && output.join("\n").includes("=> 2")) break;
  }
  const checks = [
    ["IRB evaluated typed input (9 - 7 => 2)", output.join("\n").includes("=> 2")],
  ];
  return runChecks(checks, null);
}

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
    "?": [SH, 0x38], "(": [SH, 0x26], ")": [SH, 0x27], "&": [SH, 0x24], "*": [SH, 0x25],
    "!": [SH, 0x1e], "@": [SH, 0x1f], "#": [SH, 0x20], "$": [SH, 0x21], "%": [SH, 0x22],
  };
  if (M[ch]) return M[ch];
  throw new Error("no HID mapping for char " + JSON.stringify(ch));
}

function typeString(Module, str) {
  for (const ch of str) {
    const [mod, usage] = hidForChar(ch);
    Module._harucom_kbd_set_state(mod, usage, 0, 0, 0, 0, 0);
    drive(Module, 100);
    Module._harucom_kbd_set_state(0, 0, 0, 0, 0, 0, 0);
    drive(Module, 100);
  }
}

// End-to-end IME dictionary test: type a Ruby probe that looks up the SKK
// reading にほん (entered as \u escapes so the keystrokes stay ASCII) and prints
// the candidates. The embedded /dict.bin, loaded by dict_wasm_init via the
// ports/posix dict port, must resolve it to include 日本.
function verifyDict(Module) {
  const before = output.length;
  typeString(Module, 'puts InputMethod.skk_lookup("\\u306b\\u307b\\u3093")');
  hidType(Module, [[0, 0x28]]); // Enter
  for (let i = 0; i < 40000; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
    if (i % 64 === 0 && output.slice(before).join("\n").includes("日本")) break;
  }
  const out = output.slice(before).join("\n");
  const checks = [
    ["SKK lookup of にほん includes 日本", out.includes("日本")],
  ];
  return runChecks(checks, out.split("\n").filter((l) => l.trim()).slice(-4).join(" | "));
}

// End-to-end graphics test: from IRB, switch to graphics mode and fill a red
// (RGB332 0xE0) rectangle, then assert it appears in the displayed framebuffer.
// Exercises dvi_set_mode + the DVI::Graphics drawing primitives + the wasm
// dvi_graphics_commit present path (graphics_buf -> framebuffer).
function verifyGraphics(Module) {
  const W = Module._harucom_dvi_width();
  const H = Module._harucom_dvi_height();
  const fb = Module._harucom_dvi_framebuffer();
  const center = 125 * W + 125; // center of a 50x50 rect at (100,100)

  typeString(Module, "DVI.set_mode(DVI::GRAPHICS_MODE)");
  hidType(Module, [[0, 0x28]]); // Enter
  drive(Module, 2000);
  typeString(Module, "DVI::Graphics.fill_rect(100,100,50,50,224);DVI::Graphics.commit");
  hidType(Module, [[0, 0x28]]); // Enter
  for (let i = 0; i < 40000; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
    if (i % 64 === 0 && Module.HEAPU8[fb + center] === 0xE0) break;
  }

  const px = Module.HEAPU8.subarray(fb, fb + W * H);
  let red = 0;
  for (let i = 0; i < px.length; i++) if (px[i] === 0xE0) red++;
  const checks = [
    ["graphics mode rect rendered (center pixel red)", px[center] === 0xE0],
    ["filled ~50x50 red pixels", red >= 2000],
  ];
  return runChecks(checks, `red=${red}, center=0x${px[center].toString(16)}`);
}

// End-to-end audio test: from IRB, start the PWMAudio synth on a 440Hz square
// wave and fill the ring buffer, then drain it through harucom_audio_pull (the
// same path the browser ScriptProcessorNode uses) and assert the floats form a
// real oscillating waveform. Audio can't be heard headlessly, so this verifies
// the synth + the wasm pull port produce sound.
function verifyAudio(Module) {
  typeString(Module, "PWMAudio.init(24,25);PWMAudio.tone(0,440,PWMAudio::SQUARE,15);PWMAudio.update");
  hidType(Module, [[0, 0x28]]); // Enter
  drive(Module, 8000); // let IRB evaluate the line

  const N = 512;
  const lPtr = Module._malloc(N * 4);
  const rPtr = Module._malloc(N * 4);
  const got = Module._harucom_audio_pull(lPtr, rPtr, N);
  const H = Module.HEAPF32;
  let min = Infinity, max = -Infinity, maxDelta = 0, prev = H[lPtr >> 2];
  for (let i = 0; i < N; i++) {
    const v = H[(lPtr >> 2) + i];
    if (v < min) min = v;
    if (v > max) max = v;
    const d = Math.abs(v - prev);
    if (d > maxDelta) maxDelta = d;
    prev = v;
  }
  Module._free(lPtr);
  Module._free(rPtr);
  const spread = max - min;
  // The RC low-pass rounds the square's edges, so the largest sample-to-sample
  // step is well below the peak-to-peak swing; an unfiltered square would jump
  // the full swing in one sample (maxDelta == spread).
  const checks = [
    ["synth produced samples (ring drained)", got > 0],
    ["square wave oscillates (amplitude spread)", spread > 0.5],
    ["RC low-pass smooths transitions", maxDelta < spread * 0.9],
  ];
  return runChecks(checks, `pulled=${got}, spread=${spread.toFixed(2)}, maxDelta=${maxDelta.toFixed(2)}`);
}

// End-to-end pad test: inject a single-button ADC value (the resistor-ladder
// raw value for UP on PAD0) via harucom_pad_set, then have Board::Pad read and
// decode it in IRB and confirm only UP is detected. Covers the wasm ADC shim
// through Board::Pad's decoder.
function verifyPad(Module) {
  Module._harucom_pad_set(0, 2760); // PAD0 raw for a single UP press
  const before = output.length;
  typeString(Module, 'require "board/pad";b=Board::Pad.new(28);b.read;puts [b.right?,b.up?,b.down?,b.left?].inspect');
  hidType(Module, [[0, 0x28]]); // Enter
  for (let i = 0; i < 30000; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
    if (i % 64 === 0 && output.slice(before).join("\n").includes("[false")) break;
  }
  const out = output.slice(before).join("\n");
  const checks = [
    ["Board::Pad decodes UP from injected ADC value", out.includes("[false, true, false, false]")],
  ];
  return runChecks(checks, out.split("\n").filter((l) => l.includes("[") || l.includes("error")).slice(-2).join(" | "));
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

    process.stdout.write("[Keyboard input verification]\n");
    const inputOk = verifyInput(Module);

    process.stdout.write("[IME dictionary verification]\n");
    const dictOk = verifyDict(Module);

    process.stdout.write("[Graphics mode verification]\n");
    const graphicsOk = verifyGraphics(Module);

    process.stdout.write("[Audio synth verification]\n");
    const audioOk = verifyAudio(Module);

    process.stdout.write("[ADC pad verification]\n");
    const padOk = verifyPad(Module);

    if (!bootOk || !renderOk || !inputOk || !dictOk || !graphicsOk || !audioOk || !padOk) {
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
