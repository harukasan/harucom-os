// Keyboard input gate: end-to-end keystrokes through the whole input pipeline
// (USB host stub -> Keyboard -> LineEditor -> IRB -> Sandbox eval). Type "9-7" +
// Enter (all unshifted US keys) and confirm IRB echoes "=> 2".
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("keyboard input", () => {
  let h;
  before(async () => { h = await boot(); });

  it("evaluates typed input (9 - 7 => 2) through the keyboard pipeline", () => {
    h.hidType([[0, 0x26], [0, 0x2D], [0, 0x24], [0, 0x28]]); // 9 - 7 Enter
    h.driveUntil("=> 2", 20000);
    assert.ok(h.printed().includes("=> 2"));
  });
});
