// Audio gate: from IRB, start the PWMAudio synth and drain the ring through
// harucom_audio_pull (the same path the browser ScriptProcessorNode uses). Audio
// can't be heard headlessly, so this checks the floats form a real waveform and
// the two pull-path regressions below stay fixed.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("audio synth + pull port", () => {
  let got, spread, rSpread, maxDelta, sineMaxDelta, offMaxDelta;
  before(async () => {
    const { Module, typeString, hidType, drive, ENTER } = await boot();

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
    let rmin = Infinity, rmax = -Infinity;
    maxDelta = 0;
    let prev = H[lPtr >> 2];
    for (let i = 0; i < N; i++) {
      const v = H[(lPtr >> 2) + i];
      if (v < min) min = v;
      if (v > max) max = v;
      const d = Math.abs(v - prev);
      if (d > maxDelta) maxDelta = d;
      prev = v;
      const rv = H[(rPtr >> 2) + i];
      if (rv < rmin) rmin = rv;
      if (rv > rmax) rmax = rv;
    }
    spread = max - min;
    rSpread = rmax - rmin;

    // Regression: the JS pump pulls a full block each frame, over-pulling the
    // ring, so harucom_audio_pull hits an underrun every call. It must not run
    // those silence frames through the RC/DC filters (that corrupts their state
    // and glitches the next real sample). Play a smooth sine, over-pull across
    // refill boundaries; on a clean sine every step is tiny, so any large jump is
    // a filter-corruption glitch at the boundary.
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
  // Regression: pwm_audio_init must center channel pan like the board. A
  // zero-initialized pan is L-only, so the right channel stays silent and audio
  // plays from the left speaker only.
  it("outputs the right channel (centered pan, not L-only)", () => {
    assert.ok(rSpread > 0.5, `expected R spread >0.5, got ${rSpread.toFixed(2)}`);
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
