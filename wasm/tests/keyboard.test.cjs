// DOM key events to HID report calls, and the readout the Status panel shows.
//
// This is browser-only glue with no coverage before now: the readout is the line
// to read when a key reaches the browser but not the OS, so it saying the wrong
// thing costs more than it looks.
const { describe, it, before, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const { JSDOM } = require("jsdom");

let installKeyboard, createKeyReport, canvas, report, sent, debug;

before(async () => {
  const dom = new JSDOM("<!DOCTYPE html><canvas id='screen'></canvas>", { pretendToBeVisual: true });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  globalThis.navigator = dom.window.navigator;
  ({ installKeyboard } = await import("../js/engine/keyboard.js"));
  ({ createKeyReport } = await import("../js/engine/key-report.js"));
});

beforeEach(() => {
  sent = [];
  debug = [];
  canvas = document.createElement("canvas");
  document.body.append(canvas);
  report = createKeyReport((modifier, codes) => sent.push([modifier, codes.slice()]));
  installKeyboard(canvas, report, { onDebug: (text) => debug.push(text) });
});

function key(type, init) {
  window.dispatchEvent(new window.KeyboardEvent(type, { bubbles: true, cancelable: true, ...init }));
}

describe("keyboard readout", () => {
  it("reports the code, the usage and the resulting report", () => {
    key("keydown", { code: "KeyA", key: "a" });
    assert.match(debug[debug.length - 1], /code=KeyA/);
    assert.match(debug[debug.length - 1], /usage=0x4\b/);
    assert.match(debug[debug.length - 1], /held=\[0x4\]/);
  });

  // A key the OS never sees and a key the browser also acted on look the same on
  // screen, so the readout has to say which happened.
  it("says whether the browser was stopped from acting on the key", () => {
    key("keydown", { code: "KeyJ", key: "j", ctrlKey: true });
    assert.match(debug[debug.length - 1], /prevented=true/);
    // A function key is deliberately left to the browser, so F5 still reloads.
    key("keydown", { code: "F5", key: "F5" });
    assert.match(debug[debug.length - 1], /prevented=false/);
  });

  it("reports a modifier that carries no usage of its own", () => {
    key("keydown", { code: "ShiftLeft", key: "Shift" });
    assert.match(debug[debug.length - 1], /usage=-/);
    assert.match(debug[debug.length - 1], /mod=0x2/);
  });

  // A key with no HID usage still has to be reported, because "nothing happened"
  // is exactly what the reader is trying to explain.
  it("reports a key it has no usage for", () => {
    key("keydown", { code: "Nonsense", key: "Unidentified" });
    assert.match(debug[debug.length - 1], /code=Nonsense/);
    assert.match(debug[debug.length - 1], /usage=-/);
  });

  it("reports the release as well as the press", () => {
    key("keydown", { code: "KeyA", key: "a" });
    key("keyup", { code: "KeyA", key: "a" });
    assert.match(debug[debug.length - 1], /held=\[\]/);
  });
});
