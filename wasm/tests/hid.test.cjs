// Pure-logic gate for engine/hid.js: the DOM key -> HID usage mapping. No wasm,
// no DOM; just the table and usageFor against synthetic key events.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

describe("hid mapping", () => {
  let HID, MOD, usageFor;
  before(async () => { ({ HID, MOD, usageFor } = await import("../js/engine/hid.js")); });

  it("maps letter, enter, and space codes to their HID usages", () => {
    assert.equal(usageFor({ code: "KeyA" }), 0x04);
    assert.equal(usageFor({ code: "KeyZ" }), 0x1d);
    assert.equal(usageFor({ code: "Enter" }), 0x28);
    assert.equal(usageFor({ code: "Space" }), 0x2c);
  });

  it("falls back to e.key for the space bar when the code is unknown", () => {
    assert.equal(usageFor({ code: "NumpadEnter", key: " " }), 0x2c);
  });

  it("returns undefined for an unmapped key", () => {
    assert.equal(usageFor({ code: "AudioVolumeUp", key: "x" }), undefined);
  });

  it("exposes the modifier bitmask table", () => {
    assert.equal(MOD.ControlLeft, 0x01);
    assert.equal(MOD.ShiftLeft, 0x02);
    assert.equal(MOD.MetaRight, 0x80);
  });
});
