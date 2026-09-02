// Pure-logic gate for engine/pad-ladder.js: the D-pad direction mask -> ADC raw
// math. No wasm, no DOM. A single direction must reproduce its calibration raw
// (so Board::Pad decodes it back), and combining directions must lower the raw
// (parallel resistance).
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { pathToFileURL } = require("node:url");

describe("pad ladder", () => {
  let PAD_CALIBRATION, padRawValue;
  before(async () => {
    ({ PAD_CALIBRATION, padRawValue } = await import("../js/engine/pad-ladder.js"));
  });

  it("reads idle (3V3) when nothing is pressed", () => {
    assert.equal(padRawValue(0), 4095);
  });

  // Asserting padRawValue(1 << dir) === PAD_CALIBRATION[dir] would prove
  // nothing: the conductances are derived from those same values, so the
  // identity holds for any calibration. The duplication worth guarding is
  // against the Ruby that owns the real numbers, so read them from there.
  it("uses the same calibration as Board::Pad", () => {
    const source = readFileSync(
      new URL("../../rootfs/lib/board/pad.rb", pathToFileURL(__filename)), "utf8");
    const match = source.match(/DEFAULT_CALIBRATION\s*=\s*\[([^\]]+)\]/);
    assert.ok(match, "DEFAULT_CALIBRATION not found in rootfs/lib/board/pad.rb");
    const board = match[1].split(",").map((n) => parseInt(n.trim(), 10));
    assert.deepEqual(PAD_CALIBRATION, board,
      "the browser ladder and Board::Pad must agree, or an injected press decodes wrong");
  });

  it("reproduces each direction's calibration raw for a single press", () => {
    for (let dir = 0; dir < 4; dir++) {
      assert.equal(padRawValue(1 << dir), PAD_CALIBRATION[dir], "dir " + dir);
    }
  });

  it("lowers the raw when two directions are pressed together", () => {
    const right = padRawValue(0b0001);
    const both = padRawValue(0b0011); // RIGHT + UP
    assert.ok(both < right, `both=${both} right=${right}`);
  });
});
