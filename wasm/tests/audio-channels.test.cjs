// Channel order gate, driven by panning.
//
// The mixer packs L in the low half-word by default; this port unpacks L from
// the high one and flips the flag to match. The flip has to hold from the first
// pull, because the run loop pulls before any Ruby runs, so a tone played
// without an explicit PWMAudio.init would otherwise come out of the wrong
// speaker.
//
// Panning proves the order without needing to hear it: pan 0 sends a channel
// entirely to L, pan 15 entirely to R (pan_tab_l / pan_tab_r in src/pwm_audio.c),
// so a swap shows up as the silent side carrying the tone. Measurements warm up
// first because the idle bias ramps from zero on the first pulls, and that ramp
// would otherwise dominate the swing on both channels.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

const FRAMES = 4096;

describe("audio channel order", () => {
  let silent, left, right, center;
  before(async () => {
    const { Module, typeString, hidType, drive, ENTER } = await boot();
    const lPtr = Module._malloc(FRAMES * 4);
    const rPtr = Module._malloc(FRAMES * 4);

    const swing = (ptr) => {
      const heap = Module.HEAPF32;
      let min = Infinity, max = -Infinity;
      for (let i = 0; i < FRAMES; i++) {
        const v = heap[(ptr >> 2) + i];
        if (v < min) min = v;
        if (v > max) max = v;
      }
      return max - min;
    };
    const measure = () => {
      for (let i = 0; i < 20; i++) Module._harucom_audio_pull(lPtr, rPtr, FRAMES);
      Module._harucom_audio_pull(lPtr, rPtr, FRAMES);
      return { l: swing(lPtr), r: swing(rPtr) };
    };
    const run = (line) => { typeString(line); hidType(ENTER); drive(6000); };

    silent = measure();
    // No PWMAudio.init on purpose: this is the path where the flag has to be
    // right already. The untouched pan is 0, which is hard left.
    run("PWMAudio.tone(0,440,PWMAudio::SQUARE,15)");
    left = measure();
    run("PWMAudio.pan(0,15)");
    right = measure();
    run("PWMAudio.pan(0,8)");
    center = measure();

    Module._free(lPtr);
    Module._free(rPtr);
  });

  it("is silent on both channels before anything plays", () => {
    assert.ok(silent.l < 0.01 && silent.r < 0.01,
      `expected silence, got L ${silent.l.toFixed(3)} R ${silent.r.toFixed(3)}`);
  });

  it("sends a hard-left pan to the left channel only", () => {
    assert.ok(left.l > 1.0, `expected L to carry the tone, got ${left.l.toFixed(3)}`);
    assert.ok(left.r < 0.01,
      `expected R silent, got ${left.r.toFixed(3)}. A loud R here means the port ` +
      "and the mixer disagree about which half-word holds L");
  });

  it("sends a hard-right pan to the right channel only", () => {
    assert.ok(right.r > 1.0, `expected R to carry the tone, got ${right.r.toFixed(3)}`);
    assert.ok(right.l < 0.01, `expected L silent, got ${right.l.toFixed(3)}`);
  });

  it("splits a centered pan across both", () => {
    assert.ok(center.l > 0.5 && center.r > 0.5,
      `expected both channels, got L ${center.l.toFixed(3)} R ${center.r.toFixed(3)}`);
  });
});
