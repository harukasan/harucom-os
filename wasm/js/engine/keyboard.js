// Keyboard: DOM key events -> HID usage codes -> wasm.
//
// The HID/MOD tables and usageFor live in hid.js (pure, testable). This module
// holds the live report state (held usages + modifier) and wires DOM events to
// it. The wasm USB host port (usb_host_wasm.c) holds the state and the Keyboard
// class reads it through USB::Host, so the text-input pipeline matches the
// board. The OS does its own key repeat from held state, so browser auto-repeat
// keydowns for an already-held key are harmless no-ops.

import { MOD, usageFor } from "./hid.js";

// Wire DOM keyboard events to the wasm USB host report. onDebug, when given, is
// called with a one-line status string after each event (the run loop / facade
// routes it to the keyboard debug readout). Returns { applyReleases } for the
// run loop to call once per frame.
export function installKeyboard(Module, canvas, { onDebug } = {}) {
  const held = [];   // HID usages currently down, in press order (max 6)
  let modifier = 0;  // HID modifier bitmask
  const pendingRelease = new Set(); // keyups waiting for a poll before removal

  function pushKeyState() {
    Module._harucom_kbd_set_state(modifier,
      held[0]||0, held[1]||0, held[2]||0, held[3]||0, held[4]||0, held[5]||0);
  }

  // Apply deferred key releases. Called once per frame after the scheduler batch
  // has run, so a key that went down and up within one frame is still present in
  // the report while the keyboard task polls, then removed.
  function applyReleases() {
    if (pendingRelease.size === 0) return;
    for (const usage of pendingRelease) {
      const i = held.indexOf(usage);
      if (i >= 0) held.splice(i, 1);
    }
    pendingRelease.clear();
    pushKeyState();
  }

  canvas.tabIndex = 0;          // focusable, for a visible focus target
  canvas.style.outline = "none";
  canvas.focus();
  canvas.addEventListener("mousedown", () => canvas.focus());

  function showDbg(e, usage, prevented) {
    if (!onDebug) return;
    const hex = (u) => "0x" + u.toString(16);
    onDebug(
      `last key: code=${e.code || "(none)"} key=${JSON.stringify(e.key)} ` +
      `usage=${usage === undefined ? "-" : hex(usage)} prevented=${prevented} ` +
      `held=[${held.map(hex).join(",")}] mod=${hex(modifier)}`);
  }

  function onKeyDown(e) {
    if (e.code in MOD) { modifier |= MOD[e.code]; pushKeyState(); showDbg(e, undefined, false); return; }
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
    pendingRelease.delete(usage); // re-pressed before its release was applied
    if (!held.includes(usage) && held.length < 6) held.push(usage);
    pushKeyState();
    showDbg(e, usage, prevented);
  }

  function onKeyUp(e) {
    if (e.code in MOD) { modifier &= ~MOD[e.code]; pushKeyState(); return; }
    const usage = usageFor(e);
    if (usage === undefined) return;
    // Defer removal to applyReleases so a same-frame down+up is still polled.
    pendingRelease.add(usage);
  }

  // Listen on window in the capture phase so keys reach the OS regardless of
  // which element currently holds focus (and so space never scrolls the page).
  window.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("keyup", onKeyUp, true);

  return { applyReleases };
}
