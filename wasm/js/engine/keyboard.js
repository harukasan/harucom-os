// Keyboard: DOM key events -> HID report (key-report.js) -> wasm.
//
// This is the physical-keyboard input source. The HID/MOD tables and usageFor
// live in hid.js (pure, testable); the report state machine lives in
// key-report.js (pure, testable). This module only translates DOM events into
// report calls, owns the canvas focus, and formats the debug readout. The OS
// does its own key repeat from the held state, so browser auto-repeat keydowns
// for an already-held key are harmless no-ops.

import { MOD, usageFor } from "./hid.js";

// Wire DOM keyboard events to the shared report. onDebug, when given, is called
// with a one-line status string after each event (the facade routes it to the
// keyboard debug readout).
export function installKeyboard(canvas, report, { onDebug } = {}) {
  canvas.tabIndex = 0;          // focusable, for a visible focus target
  canvas.style.outline = "none";
  canvas.focus();
  canvas.addEventListener("mousedown", () => canvas.focus());

  function showDbg(e, usage, prevented) {
    if (!onDebug) return;
    const hex = (u) => "0x" + u.toString(16);
    const { held, modifier } = report.snapshot();
    onDebug(
      `last key: code=${e.code || "(none)"} key=${JSON.stringify(e.key)} ` +
      `usage=${usage === undefined ? "-" : hex(usage)} prevented=${prevented} ` +
      `held=[${held.map(hex).join(",")}] mod=${hex(modifier)}`);
  }

  function onKeyDown(e) {
    if (e.code in MOD) { report.modifierDown(MOD[e.code]); showDbg(e, undefined, false); return; }
    const usage = usageFor(e);
    if (usage === undefined) { showDbg(e, undefined, false); return; }
    // Capture keys for the OS so the browser does not steal its shortcuts (the OS
    // uses Ctrl-J for SKK, Ctrl-C/D/L, etc.; Firefox would otherwise open
    // Downloads on Ctrl-J). Leave Meta/Cmd combos and the function keys to the
    // browser so it keeps usable escapes (F5 reload, F12 devtools, macOS Cmd-*
    // shortcuts); the OS still receives them via the report.
    const isFunctionKey = usage >= 0x3A && usage <= 0x45; // F1..F12
    let prevented = false;
    if (!e.metaKey && !isFunctionKey) { e.preventDefault(); prevented = true; }
    report.keyDown(usage);
    showDbg(e, usage, prevented);
  }

  function onKeyUp(e) {
    if (e.code in MOD) { report.modifierUp(MOD[e.code]); return; }
    const usage = usageFor(e);
    if (usage === undefined) return;
    report.keyUp(usage);
  }

  // Listen on window in the capture phase so keys reach the OS regardless of
  // which element currently holds focus (and so space never scrolls the page).
  window.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("keyup", onKeyUp, true);
}
