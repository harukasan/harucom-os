// Keyboard: DOM key events -> HID report (key-report.js) -> wasm.
//
// The HID/MOD tables and usageFor live in hid.js (pure, testable); the report
// state machine lives in key-report.js (pure, testable). This module only
// translates DOM events into report calls and owns the canvas focus. The OS does
// its own key repeat from the held state, so browser auto-repeat keydowns for an
// already-held key are harmless no-ops.

import { MOD, usageFor } from "./hid.js";

// Wire DOM keyboard events to the shared report.
export function installKeyboard(canvas, report) {
  canvas.tabIndex = 0;          // focusable, for a visible focus target
  canvas.style.outline = "none";
  canvas.focus();
  canvas.addEventListener("mousedown", () => canvas.focus());

  function onKeyDown(e) {
    if (e.code in MOD) { report.modifierDown(MOD[e.code]); return; }
    const usage = usageFor(e);
    if (usage === undefined) return;
    // Capture keys for the OS so the browser does not steal its shortcuts (the OS
    // uses Ctrl-J for SKK, Ctrl-C/D/L, etc.; Firefox would otherwise open
    // Downloads on Ctrl-J). Leave Meta/Cmd combos and the function keys to the
    // browser so it keeps usable escapes (F5 reload, F12 devtools, macOS Cmd-*
    // shortcuts); the OS still receives them via the report.
    const isFunctionKey = usage >= 0x3A && usage <= 0x45; // F1..F12
    if (!e.metaKey && !isFunctionKey) e.preventDefault();
    report.keyDown(usage);
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
