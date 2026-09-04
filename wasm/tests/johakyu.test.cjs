// The runtime the Johakyu live-coding app needs, on the browser build.
//
// Johakyu is the one app that reaches past the console: it drives a DMX rig and
// does its pattern arithmetic in exact rationals. Both were missing from the
// browser build, and neither fails at build time. The app boots, hits the first
// call and dies with a NoMethodError on Module, which is what an absent gem
// looks like from Ruby.
//
// The universe accessors are the same src/dmx.c the board runs. What is
// browser-only is ports/posix/dmx_wasm.c, which keeps the engine's bookkeeping
// and drops the wire, since there is nothing here to transmit to.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

const BG = 0x00; // palette[0], the default background

let h;

// Pixels the app has painted over the background, the way render.test.cjs
// reads them.
function nonBackgroundPixels() {
  const width = h.Module._harucom_dvi_width();
  const height = h.Module._harucom_dvi_height();
  const fb = h.Module._harucom_dvi_framebuffer();
  const px = h.Module.HEAPU8.subarray(fb, fb + width * height);
  let count = 0;
  for (let i = 0; i < px.length; i++) {
    if (px[i] !== BG) count++;
  }
  return count;
}

before(async () => {
  h = await boot();
});

describe("Johakyu runtime", () => {
  it("has C-backed Rational for the pattern core", () => {
    assert.match(h.evalInIRB("Rational(1, 3) + Rational(1, 6)", "1/2"), /\(1\/2\)/);
  });

  // Synth itself is pure Ruby (rootfs/lib/synth.rb) and picks its backend with
  // a NameError probe, so the constant exists either way. What the gem decides
  // is which backend that probe finds.
  it("renders the drum kit through the native kernels, not the Ruby fallback", () => {
    assert.match(h.evalInIRB('require "synth"; Synth::NATIVE_AVAILABLE', "=>"), /=> true/);
  });

  // Both ports return early once initialised, so a rejected argument only
  // reaches the check while the engine is still down.
  it("rejects wiring the board would reject", () => {
    const asked = 'begin; DMX.init(unit: "RP2040_UART9"); "accepted"; rescue => e; e.class.to_s; end';
    assert.match(h.evalInIRB(asked, "=>"), /ArgumentError/);
  });

  it("starts a DMX engine that has no wire to drive", () => {
    assert.match(h.evalInIRB("DMX.init", "=>"), /=> 0/);
    assert.match(h.evalInIRB("DMX.start", "=>"), /=> (nil|true)/);
  });

  it("reads back what it writes to the universe", () => {
    assert.match(h.evalInIRB("DMX.set(1, 255); DMX.get(1)", "255"), /=> 255/);
    assert.match(h.evalInIRB("DMX.set_range(10, [1, 2, 3]); [DMX.get(10), DMX.get(12)]", "]"), /\[1, 3\]/);
    assert.match(h.evalInIRB("DMX.blackout; DMX.get(1)", "=> 0"), /=> 0/);
  });

  it("counts frames while the engine runs", () => {
    const count = h.evalInIRB("DMX.frame_count", "=>").match(/=> (\d+)/);
    assert.ok(count && Number(count[1]) > 0, "frames advanced: " + count);
  });

  // A restart starts dark, the way the board's does: dmx_start blackouts so
  // the first frames overwrite whatever the fixtures latched.
  it("comes back up dark after a restart", () => {
    h.evalInIRB("DMX.set(1, 200); DMX.get(1)", "200");
    h.evalInIRB("DMX.stop", "=>");
    h.evalInIRB("DMX.start", "=>");
    assert.match(h.evalInIRB("DMX.get(1)", "=> 0"), /=> 0/);
  });

  it("boots the app far enough to paint", () => {
    const before = nonBackgroundPixels();
    const start = h.output.length;
    h.typeString("johakyu");
    h.hidType(h.ENTER);
    // Silence on stdout alone would also describe an app wedged before its
    // first cell, so wait on the screen instead and stop as soon as it fills.
    let painted = before;
    let steps = 0;
    while (steps < 150000 && painted <= before * 1.2) {
      h.drive(2000);
      steps += 2000;
      painted = nonBackgroundPixels();
    }
    const appOutput = h.output.slice(start).join("\n");
    assert.equal(appOutput, "", "johakyu printed: " + appOutput);
    assert.ok(painted > before * 1.2, `screen filled: ${before} -> ${painted} after ${steps} steps`);
  });
});
