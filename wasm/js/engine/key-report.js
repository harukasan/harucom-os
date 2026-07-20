// HID keyboard report state machine (DOM-free, wasm-free, unit-testable).
//
// This owns the live USB HID report: up to 6 held usages and the modifier byte.
// Two input sources drive it through the same API: the physical DOM keyboard
// (keyboard.js) and the on-screen keyboard panel (via the Engine facade). The
// report is pushed out through an injected setState(modifier, usages), which in
// the browser writes Module._harucom_kbd_set_state and in tests records the call.
//
// Physical and on-screen modifiers are tracked separately and OR'd only at push
// time, so a physical Shift keyup never clears the panel's latched Shift overlay.

export function createKeyReport(setState) {
  const held = [];          // HID usages currently down, in press order (max 6)
  let physModifier = 0;     // modifier bits from physical DOM modifier keys
  let softModifier = 0;     // modifier overlay from the on-screen keyboard
  const pendingRelease = new Set(); // keyups deferred until after the next poll

  function push() {
    setState(physModifier | softModifier, held.slice(0, 6));
  }

  return {
    // A key went down (physical or on-screen). Idempotent if already held.
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

    // Physical modifier key down/up (e.g. Shift, Ctrl). Touches only the physical
    // modifier, so it can never clear the on-screen overlay.
    modifierDown(bit) {
      physModifier |= bit;
      push();
    },
    modifierUp(bit) {
      physModifier &= ~bit;
      push();
    },

    // The on-screen keyboard's modifier overlay, set wholesale from its toggles.
    setOverlayModifier(mask) {
      softModifier = mask;
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

    // Read-only view for the keyboard debug readout.
    snapshot() {
      return { modifier: physModifier | softModifier, held: held.slice() };
    },
  };
}
