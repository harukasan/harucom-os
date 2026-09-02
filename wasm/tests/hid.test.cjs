// Unit tests for the DOM key to USB HID usage mapping (hid.js). Pure: the module
// touches no DOM API, it only reads the fields of a KeyboardEvent-shaped object.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

let HID, MOD, usageFor;
before(async () => { ({ HID, MOD, usageFor } = await import("../js/engine/hid.js")); });

describe("hid", () => {
  it("maps letters and digits to their HID usages", () => {
    assert.equal(usageFor({ code: "KeyA" }), 0x04);
    assert.equal(usageFor({ code: "KeyZ" }), 0x1D);
    assert.equal(usageFor({ code: "Digit1" }), 0x1E);
    assert.equal(usageFor({ code: "Digit0" }), 0x27);
  });

  it("maps the keys the OS binds shortcuts to", () => {
    assert.equal(usageFor({ code: "Enter" }), 0x28);
    assert.equal(usageFor({ code: "Escape" }), 0x29);
    assert.equal(usageFor({ code: "Backspace" }), 0x2A);
    assert.equal(usageFor({ code: "Tab" }), 0x2B);
    assert.equal(usageFor({ code: "Space" }), 0x2C);
  });

  it("returns undefined for a key with no HID usage", () => {
    assert.equal(usageFor({ code: "BrowserSearch" }), undefined);
    assert.equal(usageFor({ code: "" }), undefined);
  });

  it("keeps modifiers out of the usage table and in the modifier mask", () => {
    for (const code of Object.keys(MOD)) {
      assert.equal(HID[code], undefined, `${code} is a modifier, not a usage`);
    }
    // Left and right halves of one modifier must share a bit position pattern
    // that the OS reads as the same modifier.
    assert.ok(MOD.ShiftLeft && MOD.ShiftRight);
    assert.ok(MOD.ControlLeft && MOD.ControlRight);
  });
});
