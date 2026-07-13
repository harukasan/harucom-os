// ADC pad gate: inject a single-button ADC value (the resistor-ladder raw for UP
// on PAD0) via harucom_pad_set, then have Board::Pad read and decode it in IRB
// and confirm only UP is detected. Covers the wasm ADC shim through the decoder.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("ADC pad", () => {
  let h;
  before(async () => { h = await boot(); });

  it("decodes a pad press from an injected ADC value (UP on PAD0)", () => {
    h.Module._harucom_pad_set(0, 2760); // PAD0 raw for a single UP press
    const out = h.evalInIRB(
      'require "board/pad";b=Board::Pad.new(28);b.read;puts [b.right?,b.up?,b.down?,b.left?].inspect',
      "[false", 30000);
    assert.ok(out.includes("[false, true, false, false]"), out);
  });
});
