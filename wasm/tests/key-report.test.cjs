// Unit tests for the HID report state machine (key-report.js). Pure: no DOM, no
// wasm. A recording fake setState captures each [modifier, usages] push so the
// held/modifier/deferred-release logic can be asserted in isolation.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

let createKeyReport;
before(async () => { ({ createKeyReport } = await import("../js/engine/key-report.js")); });

// Build a fresh report plus the list of pushes it produced.
function make() {
  const calls = [];
  const report = createKeyReport((modifier, usages) => calls.push([modifier, usages.slice()]));
  return { report, calls, last: () => calls[calls.length - 1] };
}

describe("key-report", () => {
  it("pushes a held key, and keeps it held until applyReleases", () => {
    const { report, calls, last } = make();
    report.keyDown(0x04);
    assert.deepEqual(last(), [0, [0x04]]);
    const n = calls.length;
    report.keyUp(0x04);
    assert.equal(calls.length, n, "keyUp does not push (key stays reported held)");
    assert.deepEqual(last(), [0, [0x04]], "still held before applyReleases (same-frame tap is poll-safe)");
  });

  it("removes a deferred release on applyReleases, then no-ops", () => {
    const { report, calls, last } = make();
    report.keyDown(0x04);
    report.keyUp(0x04);
    report.applyReleases();
    assert.deepEqual(last(), [0, []]);
    const n = calls.length;
    report.applyReleases();
    assert.equal(calls.length, n, "applyReleases with nothing pending does not push");
  });

  it("caps held keys at 6", () => {
    const { report, last } = make();
    [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a].forEach((u) => report.keyDown(u));
    const [, usages] = last();
    assert.equal(usages.length, 6, "at most 6 usages");
    assert.ok(!usages.includes(0x0a), "the 7th key is dropped");
  });

  it("unions physical and overlay modifiers without clobbering", () => {
    const { report, last } = make();
    report.setOverlayModifier(0x02);  // on-screen Shift latched
    assert.deepEqual(last(), [0x02, []]);
    report.modifierDown(0x02);        // physical Shift down
    assert.deepEqual(last(), [0x02, []]);
    report.modifierUp(0x02);          // physical Shift up
    assert.deepEqual(last(), [0x02, []], "overlay survives the physical keyup");
    report.modifierDown(0x01);        // physical Ctrl down
    assert.deepEqual(last(), [0x03, []]);
    report.keyDown(0x04);
    assert.deepEqual(last(), [0x03, [0x04]]);
    report.setOverlayModifier(0);     // unlatch on-screen Shift
    assert.deepEqual(last(), [0x01, [0x04]]);
  });
});
