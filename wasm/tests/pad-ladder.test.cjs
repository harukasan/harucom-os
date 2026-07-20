// Pure-logic gate for engine/pad-ladder.js: the D-pad direction mask -> ADC raw
// math. No wasm, no DOM. A single direction must reproduce its calibration raw
// (so Board::Pad decodes it back), and combining directions must lower the raw
// (parallel resistance).
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

describe("pad ladder", () => {
  let PAD_CAL, padRawValue;
  before(async () => { ({ PAD_CAL, padRawValue } = await import("../js/engine/pad-ladder.js")); });

  it("reads idle (3V3) when nothing is pressed", () => {
    assert.equal(padRawValue(0), 4095);
  });

  it("reproduces each direction's calibration raw for a single press", () => {
    for (let dir = 0; dir < 4; dir++) {
      assert.equal(padRawValue(1 << dir), PAD_CAL[dir], "dir " + dir);
    }
  });

  it("lowers the raw when two directions are pressed together", () => {
    const right = padRawValue(0b0001);
    const both = padRawValue(0b0011); // RIGHT + UP
    assert.ok(both < right, `both=${both} right=${right}`);
  });
});
