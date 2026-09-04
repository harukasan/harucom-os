// The runtime the Johakyu live-coding app needs, on the browser build.
//
// Johakyu is the one app that reaches past the console: it drives a DMX rig and
// it does its pattern arithmetic in exact rationals. Both were missing from the
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

let h, appOutput;

before(async () => {
  h = await boot();
});

describe("Johakyu runtime", () => {
  it("has C-backed Rational for the pattern core", () => {
    assert.match(h.evalInIRB("Rational(1, 3) + Rational(1, 6)", "1/2"), /\(1\/2\)/);
  });

  it("has the synthesis kernels the drum kit renders through", () => {
    assert.match(h.evalInIRB("defined?(Synth)", "=>"), /"constant"/);
  });

  it("starts a DMX engine that has no wire to drive", () => {
    assert.match(h.evalInIRB("DMX.init", "=>"), /=> 0/);
    h.evalInIRB("DMX.start", "=>");
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

  it("boots the app without dying on a missing module", () => {
    const start = h.output.length;
    h.typeString("johakyu");
    h.hidType(h.ENTER);
    h.drive(150000);
    appOutput = h.output.slice(start).join("\n");
    // A full-screen app draws to the framebuffer, so silence on stdout is the
    // healthy case and any line here is a backtrace.
    assert.equal(appOutput, "", "johakyu printed: " + appOutput);
  });
});
