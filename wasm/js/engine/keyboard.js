// Keyboard: DOM key events -> HID report (key-report.js) -> wasm.
//
// The HID/MOD tables and usageFor live in hid.js (pure, testable). The report
// state machine lives in key-report.js (pure, testable). This module only
// translates DOM events into report calls and owns the canvas focus. The OS does
// its own key repeat from the held state, so browser auto-repeat keydowns for an
// already-held key carry no new state, which key-report.js drops.

import { MOD, usageFor } from "./hid.js";

// Wire DOM keyboard events to the shared report. onDebug, when given, is called
// with a one-line readout after each event, which the keys panel displays.
export function installKeyboard(canvas, report, { onDebug } = {}) {
  canvas.tabIndex = 0;          // focusable, for a visible focus target
  canvas.style.outline = "none";
  canvas.focus();
  canvas.addEventListener("mousedown", () => canvas.focus());

  // Why the readout carries `prevented`: a key the OS never receives and a key
  // the browser also acted on look the same on screen otherwise.
  function debug(e, usage, prevented) {
    if (!onDebug) return;
    const hex = (u) => "0x" + u.toString(16);
    const { held, modifier } = report.snapshot();
    onDebug(`code=${e.code || "(none)"} key=${JSON.stringify(e.key)} ` +
            `usage=${usage === undefined ? "-" : hex(usage)} prevented=${prevented} ` +
            `held=[${held.map(hex).join(",")}] mod=${hex(modifier)}`);
  }

  function onKeyDown(e) {
    if (e.code in MOD) { report.modifierDown(MOD[e.code]); debug(e, undefined, false); return; }
    const usage = usageFor(e);
    if (usage === undefined) { debug(e, undefined, false); return; }
    // Capture keys for the OS so the browser does not steal its shortcuts (the OS
    // uses Ctrl-J for SKK, Ctrl-C/D/L, and so on, so Firefox would otherwise
    // open Downloads on Ctrl-J). Leave Meta/Cmd combos and the function keys to the
    // browser so it keeps usable escapes (F5 reload, F12 devtools, macOS Cmd-*
    // shortcuts). The OS still receives them via the report.
    const isFunctionKey = usage >= 0x3A && usage <= 0x45; // F1..F12
    const prevented = !e.metaKey && !isFunctionKey;
    if (prevented) e.preventDefault();
    report.keyDown(usage);
    debug(e, usage, prevented);
  }

  function onKeyUp(e) {
    if (e.code in MOD) { report.modifierUp(MOD[e.code]); debug(e, undefined, false); return; }
    const usage = usageFor(e);
    if (usage === undefined) { debug(e, undefined, false); return; }
    report.keyUp(usage);
    debug(e, usage, false);
  }

  // Listen on window in the capture phase so keys reach the OS regardless of
  // which element currently holds focus (and so space never scrolls the page).
  window.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("keyup", onKeyUp, true);

  // A modifier held while focus leaves the window never gets its keyup, so it
  // would stay latched and turn every later keystroke into a chord. Drop the
  // whole report when the page loses focus or is hidden.
  const releaseAll = () => report.reset();
  window.addEventListener("blur", releaseAll);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) releaseAll();
  });
}
