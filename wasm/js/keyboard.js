// Keyboard: DOM key events -> HID usage codes -> wasm.
//
// Map KeyboardEvent.code to USB HID keyboard usage IDs (the codes a real USB
// keyboard reports) and modifier keys to the HID modifier bitmask. The wasm USB
// host port (usb_host_wasm.c) holds this state and the Keyboard class reads it
// through USB::Host, so the text-input pipeline matches the board. The OS does
// its own key repeat from held state, so browser auto-repeat keydowns for an
// already-held key are harmless no-ops.

const HID = {
  KeyA:0x04,KeyB:0x05,KeyC:0x06,KeyD:0x07,KeyE:0x08,KeyF:0x09,KeyG:0x0A,
  KeyH:0x0B,KeyI:0x0C,KeyJ:0x0D,KeyK:0x0E,KeyL:0x0F,KeyM:0x10,KeyN:0x11,
  KeyO:0x12,KeyP:0x13,KeyQ:0x14,KeyR:0x15,KeyS:0x16,KeyT:0x17,KeyU:0x18,
  KeyV:0x19,KeyW:0x1A,KeyX:0x1B,KeyY:0x1C,KeyZ:0x1D,
  Digit1:0x1E,Digit2:0x1F,Digit3:0x20,Digit4:0x21,Digit5:0x22,
  Digit6:0x23,Digit7:0x24,Digit8:0x25,Digit9:0x26,Digit0:0x27,
  Enter:0x28,Escape:0x29,Backspace:0x2A,Tab:0x2B,Space:0x2C,
  Minus:0x2D,Equal:0x2E,BracketLeft:0x2F,BracketRight:0x30,Backslash:0x31,
  Semicolon:0x33,Quote:0x34,Backquote:0x35,Comma:0x36,Period:0x37,Slash:0x38,
  CapsLock:0x39,
  F1:0x3A,F2:0x3B,F3:0x3C,F4:0x3D,F5:0x3E,F6:0x3F,
  F7:0x40,F8:0x41,F9:0x42,F10:0x43,F11:0x44,F12:0x45,
  Insert:0x49,Home:0x4A,PageUp:0x4B,Delete:0x4C,End:0x4D,PageDown:0x4E,
  ArrowRight:0x4F,ArrowLeft:0x50,ArrowDown:0x51,ArrowUp:0x52,
  IntlRo:0x87,IntlYen:0x89,
};
const MOD = {
  ControlLeft:0x01,ShiftLeft:0x02,AltLeft:0x04,MetaLeft:0x08,
  ControlRight:0x10,ShiftRight:0x20,AltRight:0x40,MetaRight:0x80,
};

// Wire DOM keyboard events to the wasm USB host report. Returns { applyReleases }
// for the run loop to call once per frame.
export function installKeyboard(Module, canvas, dbgEl) {
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

  // Resolve a DOM key event to a HID usage. Keyed on e.code, but fall back to
  // e.key for the space bar: some browsers / IME states report its code as
  // something other than "Space", while e.key is always " ".
  function usageFor(e) {
    let u = HID[e.code];
    if (u === undefined && e.key === " ") u = 0x2C;
    return u;
  }

  function showDbg(e, usage, prevented) {
    if (!dbgEl) return;
    const hex = (u) => "0x" + u.toString(16);
    dbgEl.textContent =
      `last key: code=${e.code || "(none)"} key=${JSON.stringify(e.key)} ` +
      `usage=${usage === undefined ? "-" : hex(usage)} prevented=${prevented} ` +
      `held=[${held.map(hex).join(",")}] mod=${hex(modifier)}`;
  }

  function onKeyDown(e) {
    if (e.code in MOD) { modifier |= MOD[e.code]; pushKeyState(); showDbg(e, undefined, false); return; }
    const usage = usageFor(e);
    if (usage === undefined) { showDbg(e, undefined, false); return; }
    // Capture keys for the OS so the browser does not steal its shortcuts (the OS
    // uses Ctrl-J for SKK, Ctrl-C/D/L, etc. — Firefox would otherwise open
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
