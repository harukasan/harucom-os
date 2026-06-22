/*
 * Headless smoke test of the Harucom OS wasm build, on the node:test runner.
 *
 *   rake wasm:test   (or: node --test wasm/run_node.test.cjs)
 *
 * The build is based on the picoruby-wasm gem, whose JS interop init requires a
 * DOM (window/document). jsdom provides a real one so this exercises the same
 * gem init the browser does, rather than hand-rolled stubs. The real target is
 * the browser (rake wasm:server); this harness is for headless smoke testing.
 *
 * This is one ordered integration scenario, not isolated unit tests: a single
 * VM is booted once (the top-level before(), ~200k scheduler steps) and the
 * stages then drive that same live IRB in order (input typed into IRB, graphics
 * mode switched, the synth set up, ...). node:test runs describe/it in source
 * order, so each stage's setup runs after the previous stage. A stage with
 * several assertions measures once in its own before() and asserts the captured
 * values in separate it()s, so every gate is reported independently.
 */
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { JSDOM } = require("jsdom");

// The picoruby-wasm gem's JS init needs a DOM; set up the jsdom globals before
// the emscripten module is required (it probes window/document at load time).
const dom = new JSDOM(
  '<!DOCTYPE html><canvas id="screen" width="640" height="480"></canvas>',
  { pretendToBeVisual: true }
);
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.navigator = dom.window.navigator;

const createHarucomModule = require("../build/wasm/harucom.js");

// Shared across the suite: the single booted VM, the boot step count, and every
// line the wasm prints (fd 1 / 2 via the posix hal_write). before() fills these.
let Module;
let bootSteps;
const output = [];
const printed = () => output.join("\n");

// --- scheduler / input helpers ---------------------------------------------

// Drive the cooperative scheduler the way the browser run loop does: tick the
// clock (so sleep_ms / DVI.wait_vsync tasks wake) then run one step.
function drive(steps) {
  for (let i = 0; i < steps; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
  }
}

// Drive until `marker` appears in the output (or maxSteps elapse); returns the
// number of steps taken. Used to wait for the IRB banner and for echoed results.
function driveUntil(marker, maxSteps) {
  for (let i = 0; i < maxSteps; i++) {
    Module._mrb_tick_wasm();
    Module._mrb_run_step();
    if (i % 64 === 0 && printed().includes(marker)) return i + 1;
  }
  return maxSteps;
}

// Inject HID keystrokes the way the browser keydown/keyup handlers do: set the
// report with one usage held so the keyboard task polls the press, then clear it
// so it polls the release. Held only briefly so the OS key repeat (400ms) never
// fires (board_millis is real wall-clock time).
function hidType(keys) {
  for (const [modifier, usage] of keys) {
    Module._harucom_kbd_set_state(modifier, usage, 0, 0, 0, 0, 0);
    drive(200);
    Module._harucom_kbd_set_state(0, 0, 0, 0, 0, 0, 0);
    drive(200);
  }
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

// Type a line into IRB (string + Enter) and drive until its result is echoed.
function evalInIRB(line, expect, maxSteps = 40000) {
  const start = output.length;
  typeString(line);
  hidType(ENTER);
  driveUntil(expect, maxSteps);
  return output.slice(start).join("\n");
}

// --- the suite -------------------------------------------------------------

describe("Harucom OS wasm smoke test", () => {
  // Boot one VM: create the module, init the VM + MEMFS rootfs + scheduler, then
  // drive the scheduler until /system.rb reaches the IRB banner (every require
  // resolved and IRB started). A failed require or a raised exception would stop
  // before the banner, failing the boot stage below.
  before(async () => {
    Module = await createHarucomModule({
      print: (s) => output.push(s),
      printErr: (s) => output.push(s),
    });
    assert.equal(Module._harucom_init(), 0, "harucom_init (VM + MEMFS rootfs + scheduler)");
    bootSteps = driveUntil("Powered by PicoRuby", 200000);
  });

  // The Console mirrors its DVI output to the original STDOUT (fd 1), so the
  // banner is captured here even though it is really painted on the text surface.
  describe("boots the Ruby userland to IRB", () => {
    it("deploys the rootfs to MEMFS", (t) => {
      t.diagnostic(`drove ${bootSteps} scheduler steps`);
      assert.match(printed(), /rootfs: deployed \d+ files/);
    });
    it("reaches the IRB banner (every require resolved)", () => {
      assert.ok(printed().includes("Powered by PicoRuby"));
    });
    it("prints the banner author line", () => {
      assert.ok(printed().includes("Shunsuke Michii"));
    });
  });

  // The banner is drawn on the DVI text surface and committed, so after boot the
  // framebuffer (the same pixels the browser canvas blits) holds non-bg pixels.
  describe("renders the console into the framebuffer", () => {
    let width, height, nonbg, colors, frames;
    before(() => {
      width = Module._harucom_dvi_width();
      height = Module._harucom_dvi_height();
      const fb = Module._harucom_dvi_framebuffer();
      const px = Module.HEAPU8.subarray(fb, fb + width * height);
      const BG = 0x00; // palette[0], default background (see default_palette[])
      nonbg = 0;
      colors = new Set();
      for (let i = 0; i < px.length; i++) {
        if (px[i] !== BG) nonbg++;
        colors.add(px[i]);
      }
      frames = Module._harucom_dvi_frame_count();
    });
    it("is 640x480", () => {
      assert.equal(width, 640);
      assert.equal(height, 480);
    });
    it("has non-background pixels", (t) => {
      t.diagnostic(`non-bg=${nonbg}, distinct colors=${colors.size}`);
      assert.ok(nonbg > 500, `expected >500 non-bg pixels, got ${nonbg}`);
    });
    it("committed at least one frame", () => {
      assert.ok(frames > 0);
    });
  });

  // End-to-end keystroke test through the whole input pipeline (USB host stub ->
  // Keyboard -> LineEditor -> IRB -> Sandbox eval): type "9-7" + Enter (all
  // unshifted US keys) and confirm IRB echoes "=> 2".
  it("evaluates typed input (9 - 7 => 2) through the keyboard pipeline", () => {
    hidType([[0, 0x26], [0, 0x2D], [0, 0x24], [0, 0x28]]); // 9 - 7 Enter
    driveUntil("=> 2", 20000);
    assert.ok(printed().includes("=> 2"));
  });

  // The opcode-budget preemption hook must split a long busy Ruby loop across
  // many mrb_run_step calls. The driver only ticks the clock between steps, so
  // without the hook the whole loop would run inside a single mrb_run_step (and
  // in the browser would freeze the tab); with it, the loop yields every budget
  // of opcodes, so it takes many steps to finish.
  describe("preempts a busy Ruby loop (opcode-budget hook)", () => {
    let steps, done;
    before(() => {
      const start = output.length;
      typeString("i=0;while i<1000000;i=i+1;end;puts i");
      hidType(ENTER);
      steps = 0;
      done = false;
      for (let i = 0; i < 100000; i++) {
        Module._mrb_tick_wasm();
        Module._mrb_run_step();
        steps++;
        if (output.slice(start).join("").includes("1000000")) { done = true; break; }
      }
    });
    it("completes the loop", () => assert.ok(done));
    it("spread the loop across many steps (hook active)", (t) => {
      t.diagnostic(`steps=${steps}`);
      assert.ok(steps > 50, `expected >50 steps, got ${steps}`);
    });
  });

  // End-to-end IME dictionary test: look up the SKK reading にほん (entered as \u
  // escapes so the keystrokes stay ASCII). The embedded /dict.bin, loaded by
  // dict_wasm_init via the ports/posix dict port, must resolve it to include 日本.
  it("resolves an SKK dictionary lookup (にほん -> 日本)", () => {
    const out = evalInIRB('puts InputMethod.skk_lookup("\\u306b\\u307b\\u3093")', "日本");
    assert.ok(out.includes("日本"), out);
  });

  // From IRB, switch to graphics mode and fill a red (RGB332 0xE0) rectangle,
  // then assert it appears in the displayed framebuffer. Exercises dvi_set_mode +
  // the DVI::Graphics primitives + the wasm dvi_graphics_commit present path.
  describe("draws in graphics mode", () => {
    const W = 640;
    const center = 125 * W + 125; // center of a 50x50 rect at (100,100)
    let centerPixel, red;
    before(() => {
      const fb = Module._harucom_dvi_framebuffer();
      typeString("DVI.set_mode(DVI::GRAPHICS_MODE)");
      hidType(ENTER);
      drive(2000);
      typeString("DVI::Graphics.fill_rect(100,100,50,50,224);DVI::Graphics.commit");
      hidType(ENTER);
      for (let i = 0; i < 40000; i++) {
        Module._mrb_tick_wasm();
        Module._mrb_run_step();
        if (i % 64 === 0 && Module.HEAPU8[fb + center] === 0xE0) break;
      }
      const px = Module.HEAPU8.subarray(fb, fb + W * 480);
      centerPixel = px[center];
      red = 0;
      for (let i = 0; i < px.length; i++) if (px[i] === 0xE0) red++;
    });
    it("renders the rect (center pixel is red)", (t) => {
      t.diagnostic(`red=${red}, center=0x${centerPixel.toString(16)}`);
      assert.equal(centerPixel, 0xE0);
    });
    it("fills ~50x50 red pixels", () => {
      assert.ok(red >= 2000, `expected >=2000 red pixels, got ${red}`);
    });
  });

  // From IRB, start the PWMAudio synth and drain the ring through
  // harucom_audio_pull (the same path the browser ScriptProcessorNode uses).
  // Audio can't be heard headlessly, so this checks the floats form a real
  // waveform and the two pull-path regressions below stay fixed.
  describe("produces audio through the synth + pull port", () => {
    let got, spread, maxDelta, sineMaxDelta, offMaxDelta;
    before(() => {
      typeString("PWMAudio.init(24,25);PWMAudio.tone(0,440,PWMAudio::SQUARE,15);PWMAudio.update");
      hidType(ENTER);
      drive(8000); // let IRB evaluate the line

      const CAP = 1024;
      const lPtr = Module._malloc(CAP * 4);
      const rPtr = Module._malloc(CAP * 4);
      const N = 512;
      got = Module._harucom_audio_pull(lPtr, rPtr, N);
      const H = Module.HEAPF32;
      let min = Infinity, max = -Infinity;
      maxDelta = 0;
      let prev = H[lPtr >> 2];
      for (let i = 0; i < N; i++) {
        const v = H[(lPtr >> 2) + i];
        if (v < min) min = v;
        if (v > max) max = v;
        const d = Math.abs(v - prev);
        if (d > maxDelta) maxDelta = d;
        prev = v;
      }
      spread = max - min;

      // Regression: the JS pump pulls a full block each frame, over-pulling the
      // ring, so harucom_audio_pull hits an underrun every call. It must not run
      // those silence frames through the RC/DC filters (that corrupts their state
      // and glitches the next real sample). Play a smooth sine, over-pull across
      // refill boundaries; on a clean sine every step is tiny, so any large jump
      // is a filter-corruption glitch at the boundary.
      typeString("PWMAudio.tone(0,440,PWMAudio::SINE,8)");
      hidType(ENTER);
      drive(4000);
      const sine = [];
      for (let k = 0; k < 3; k++) {
        typeString("PWMAudio.update");
        hidType(ENTER);
        drive(2000);
        const g = Module._harucom_audio_pull(lPtr, rPtr, CAP); // over-pull (ring < CAP)
        const HH = Module.HEAPF32;
        if (k >= 1) for (let i = 0; i < g; i++) sine.push(HH[(lPtr >> 2) + i]);
      }
      sineMaxDelta = 0;
      for (let i = 1; i < sine.length; i++) {
        sineMaxDelta = Math.max(sineMaxDelta, Math.abs(sine[i] - sine[i - 1]));
      }

      // Regression: stopping a note must ramp the amplitude out (the synth's
      // attack/release envelope), not cut it, which would step the waveform's DC
      // and click. Capture continuously across a stop; the step stays tiny when
      // ramped but is ~0.18 if the note is cut abruptly.
      const off = [];
      const pullOff = () => {
        typeString("PWMAudio.update");
        hidType(ENTER);
        drive(1200);
        const g = Module._harucom_audio_pull(lPtr, rPtr, 800);
        const HH = Module.HEAPF32;
        for (let i = 0; i < g; i++) off.push(HH[(lPtr >> 2) + i]);
      };
      pullOff(); // still sounding
      typeString("PWMAudio.stop(0)");
      hidType(ENTER);
      drive(300);
      pullOff(); pullOff(); // release ramp, then silence
      offMaxDelta = 0;
      for (let i = 1; i < off.length; i++) {
        offMaxDelta = Math.max(offMaxDelta, Math.abs(off[i] - off[i - 1]));
      }

      Module._free(lPtr);
      Module._free(rPtr);
    });

    it("drains samples from the ring", (t) => {
      t.diagnostic(`pulled=${got}, spread=${spread.toFixed(2)}, maxDelta=${maxDelta.toFixed(2)}, ` +
        `sineMaxDelta=${sineMaxDelta.toFixed(3)}, offMaxDelta=${offMaxDelta.toFixed(3)}`);
      assert.ok(got > 0);
    });
    it("oscillates (square wave amplitude spread)", () => {
      assert.ok(spread > 0.5, `expected spread >0.5, got ${spread.toFixed(2)}`);
    });
    // The RC low-pass rounds the square's edges, so the largest sample-to-sample
    // step is well below the peak-to-peak swing; an unfiltered square would jump
    // the full swing in one sample (maxDelta == spread).
    it("smooths transitions through the RC low-pass", () => {
      assert.ok(maxDelta < spread * 0.9, `maxDelta=${maxDelta.toFixed(2)} vs spread=${spread.toFixed(2)}`);
    });
    // A 440Hz sine steps by at most ~0.03 between samples, so 0.08 flags an
    // underrun-boundary glitch.
    it("has no underrun-boundary glitch on sine", () => {
      assert.ok(sineMaxDelta > 0, "no sine samples captured");
      assert.ok(sineMaxDelta < 0.08, `sineMaxDelta=${sineMaxDelta.toFixed(3)}`);
    });
    // 0.08 flags an un-ramped note-off (a cut note jumps ~0.18).
    it("ramps note-off out (no click)", () => {
      assert.ok(offMaxDelta > 0, "no note-off samples captured");
      assert.ok(offMaxDelta < 0.08, `offMaxDelta=${offMaxDelta.toFixed(3)}`);
    });
  });

  // Inject a single-button ADC value (the resistor-ladder raw for UP on PAD0)
  // via harucom_pad_set, then have Board::Pad read and decode it in IRB and
  // confirm only UP is detected. Covers the wasm ADC shim through the decoder.
  it("decodes a pad press from an injected ADC value (UP on PAD0)", () => {
    Module._harucom_pad_set(0, 2760); // PAD0 raw for a single UP press
    const out = evalInIRB(
      'require "board/pad";b=Board::Pad.new(28);b.read;puts [b.right?,b.up?,b.down?,b.left?].inspect',
      "[false", 30000);
    assert.ok(out.includes("[false, true, false, false]"), out);
  });
});
