// Unit tests for the HID report state machine (key-report.js). Pure: no DOM, no
// wasm. A recording fake setState captures each [modifier, usages] push, and
// flush() is called the way the run loop calls it, once per simulated frame.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

let createKeyReport;
before(async () => { ({ createKeyReport } = await import("../js/engine/key-report.js")); });

function make() {
  const calls = [];
  const report = createKeyReport((modifier, usages) => calls.push([modifier, usages.slice()]));
  // Drain every queued state, as successive frames would.
  const drain = () => { while (report.pending()) report.flush(); };
  return { report, calls, drain, last: () => calls[calls.length - 1] };
}

describe("key-report", () => {
  it("publishes one state per flush, not the latest", () => {
    const { report, calls, last } = make();
    report.keyDown(0x04);
    report.keyUp(0x04);
    assert.equal(calls.length, 0, "nothing is published until the run loop flushes");
    report.flush();
    assert.deepEqual(last(), [0, [0x04]], "the press is seen first");
    report.flush();
    assert.deepEqual(last(), [0, []], "the release is seen on the next frame");
  });

  it("keeps a key pressed and released between frames from being lost", () => {
    const { report, calls } = make();
    report.keyDown(0x04);
    report.keyUp(0x04);
    report.flush();
    assert.deepEqual(calls[0], [0, [0x04]], "the OS still gets a frame with the key held");
  });

  it("caps held keys at 6", () => {
    const { report, drain, last } = make();
    [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a].forEach((u) => report.keyDown(u));
    drain();
    const [, usages] = last();
    assert.equal(usages.length, 6, "at most 6 usages");
    assert.ok(!usages.includes(0x0a), "the 7th key is dropped");
  });

  it("shifts only the key that was pressed while the modifier was down", () => {
    const { report, calls, drain } = make();
    // Typing "Hi" fast: Shift, H, release both, then i, all inside one frame.
    report.modifierDown(0x02);
    report.keyDown(0x0B);   // H
    report.keyUp(0x0B);
    report.modifierUp(0x02);
    report.keyDown(0x0C);   // i
    drain();
    const shifted = calls.filter(([mod, keys]) => mod === 0x02 && keys.includes(0x0B));
    const bare = calls.filter(([mod, keys]) => mod === 0 && keys.includes(0x0C));
    assert.ok(shifted.length > 0, "H is reported with Shift held");
    assert.ok(bare.length > 0, "i is reported with no modifier");
    assert.ok(!calls.some(([mod, keys]) => mod === 0x02 && keys.includes(0x0C)),
              "i must never be reported as shifted, or fast typing capitalizes it");
  });

  it("never reports Ctrl-Alt together with Delete when they were released first", () => {
    const { report, calls, drain } = make();
    const CTRL = 0x01, ALT = 0x04, DELETE = 0x4C;
    report.modifierDown(CTRL);
    report.modifierDown(ALT);
    report.modifierUp(CTRL);
    report.modifierUp(ALT);
    report.keyDown(DELETE);
    drain();
    // usb_host_wasm.c reboots the page on this combination, so a collapsed
    // report here would throw the session away.
    assert.ok(!calls.some(([mod, keys]) =>
      (mod & CTRL) && (mod & ALT) && keys.includes(DELETE)), "no spurious reboot chord");
  });

  it("collapses a repeat keydown, so holding a key cannot outrun the drain", () => {
    const { report } = make();
    report.keyDown(0x04);
    for (let i = 0; i < 50; i++) report.keyDown(0x04); // browser auto-repeat
    assert.equal(report.pending(), 1, "the repeats carry no new state");
  });

  it("keeps queued keystrokes on reset, which the OS has not seen yet", () => {
    const { report, calls, drain } = make();
    report.keyDown(0x04);   // typed, then focus leaves in the same frame
    report.reset();
    drain();
    assert.ok(calls.some(([, keys]) => keys.includes(0x04)),
              "the keystroke must still reach the OS");
    assert.deepEqual(calls[calls.length - 1], [0, []], "and the release lands after it");
  });

  it("releases everything on reset, so a modifier held across a blur cannot latch", () => {
    const { report, drain, last } = make();
    report.modifierDown(0x04);  // Alt down, then focus leaves
    report.keyDown(0x2B);       // Tab
    report.reset();
    drain();
    assert.deepEqual(last(), [0, []]);
  });

  // The on-screen keyboard latches Shift/Ctrl/Alt as toggles, which have to
  // combine with the physical keys rather than replace them: holding a physical
  // Ctrl while the panel latch says Shift must report both.
  it("ORs the on-screen latches with the physical modifiers", () => {
    const { report, drain, last } = make();
    report.setOverlayModifier(0x02); // panel latches Shift
    report.modifierDown(0x01);       // physical Ctrl goes down
    report.keyDown(0x04);            // A
    drain();
    assert.deepEqual(last(), [0x03, [0x04]]);
  });

  it("drops the latch when the panel clears it", () => {
    const { report, drain, last } = make();
    report.setOverlayModifier(0x02);
    report.keyDown(0x04);
    drain();
    assert.deepEqual(last(), [0x02, [0x04]]);
    report.setOverlayModifier(0);
    drain();
    assert.deepEqual(last(), [0, [0x04]]);
  });

  // reset() runs when the page loses focus. The panel toggles stay lit across
  // that, so clearing them here would leave the report disagreeing with the UI.
  it("keeps the on-screen latch across a reset", () => {
    const { report, drain, last } = make();
    report.setOverlayModifier(0x02);
    report.keyDown(0x04);
    report.reset();
    drain();
    assert.deepEqual(last(), [0x02, []]);
  });

  it("reports the live state for the keys readout", () => {
    const { report } = make();
    report.modifierDown(0x01);
    report.setOverlayModifier(0x02);
    report.keyDown(0x04);
    assert.deepEqual(report.snapshot(), { held: [0x04], modifier: 0x03 });
  });

  it("hands the readout a copy, so a reader cannot edit the report", () => {
    const { report } = make();
    report.keyDown(0x04);
    report.snapshot().held.push(0x05);
    assert.deepEqual(report.snapshot().held, [0x04]);
  });
});
