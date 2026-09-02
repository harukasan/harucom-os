// HID keyboard report state machine (DOM-free, wasm-free, unit-testable).
//
// This owns the live USB HID report: up to 6 held usages and the modifier byte.
// keyboard.js drives it from DOM events. The report is pushed out through an
// injected setState(modifier, usages), which in the browser writes
// Module._harucom_kbd_set_state and in tests records the call.

export function createKeyReport(setState) {
  const held = [];          // HID usages currently down, in press order (max 6)
  let modifier = 0;         // HID modifier bitmask from the modifier keys
  const pendingRelease = new Set(); // keyups deferred until after the next poll

  function push() {
    setState(modifier, held.slice(0, 6));
  }

  return {
    // A key went down. Idempotent if already held.
    keyDown(usage) {
      pendingRelease.delete(usage); // re-pressed before its release was applied
      if (!held.includes(usage) && held.length < 6) held.push(usage);
      push();
    },

    // A key went up. The release is deferred to applyReleases so a key that went
    // down and up within one frame is still in the report when the Ruby keyboard
    // task polls. No push here: the key stays reported held until then.
    keyUp(usage) {
      pendingRelease.add(usage);
    },

    // Modifier key down/up (e.g. Shift, Ctrl).
    modifierDown(bit) {
      modifier |= bit;
      push();
    },
    modifierUp(bit) {
      modifier &= ~bit;
      push();
    },

    // Drop every held key and modifier at once. The keyboard calls this when
    // the page loses focus, where the browser stops delivering keyup.
    reset() {
      held.length = 0;
      modifier = 0;
      pendingRelease.clear();
      push();
    },

    // Apply deferred releases. Called once per frame by the run loop after the
    // scheduler batch (and the keyboard poll) has run.
    applyReleases() {
      if (pendingRelease.size === 0) return;
      for (const usage of pendingRelease) {
        const i = held.indexOf(usage);
        if (i >= 0) held.splice(i, 1);
      }
      pendingRelease.clear();
      push();
    },
  };
}
