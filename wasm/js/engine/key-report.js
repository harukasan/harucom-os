// HID keyboard report state machine (DOM-free, wasm-free, unit-testable).
//
// This owns the live USB HID report: up to 6 held usages and the modifier byte.
// keyboard.js drives it from DOM events. Reports are pushed out through an
// injected setState(modifier, usages), which in the browser writes
// Module._harucom_kbd_set_state and in tests records the call.
//
// A report is a state, not an event, and the OS polls it. Several DOM events
// can land between two polls, so the states are queued and flush() publishes
// one per frame. That way every distinct state gets a frame in which the OS can
// see it. Collapsing them instead loses keystrokes (a key pressed and released
// between polls) or attributes a modifier to the wrong key (releasing Shift and
// pressing the next letter in one frame would shift that letter too, and
// releasing Ctrl-Alt before Delete would report the reboot chord).
export function createKeyReport(setState) {
  const held = [];   // HID usages currently down, in press order (max 6)
  let modifier = 0;  // HID modifier bitmask from the physical modifier keys
  let overlay = 0;   // HID modifier bitmask latched by the on-screen keyboard
  const queue = [];  // states awaiting a frame, oldest first
  let published = [0, []]; // the last state handed to setState

  function same(a, b) {
    return a[0] === b[0] && a[1].length === b[1].length &&
           a[1].every((usage, i) => usage === b[1][i]);
  }

  // Queue the current state, unless it is the one already waiting or already
  // published. The browser repeats keydown for a held key, and the OS does its
  // own repeat from the held state, so those repeats carry nothing new. Queueing
  // them would grow the queue faster than the one-per-frame drain empties it.
  function record() {
    const state = [modifier | overlay, held.slice(0, 6)];
    const latest = queue.length ? queue[queue.length - 1] : published;
    if (same(state, latest)) return;
    queue.push(state);
  }

  return {
    // A key went down. Idempotent if already held.
    keyDown(usage) {
      if (!held.includes(usage) && held.length < 6) held.push(usage);
      record();
    },

    // A key went up.
    keyUp(usage) {
      const i = held.indexOf(usage);
      if (i >= 0) held.splice(i, 1);
      record();
    },

    // Modifier key down/up (e.g. Shift, Ctrl).
    modifierDown(bit) {
      modifier |= bit;
      record();
    },
    modifierUp(bit) {
      modifier &= ~bit;
      record();
    },

    // Drop every held key and modifier at once. The keyboard calls this when the
    // page loses focus, where the browser stops delivering keyup. States already
    // queued are kept: they are keystrokes the OS has not seen yet, and the
    // release below lands after them.
    reset() {
      held.length = 0;
      modifier = 0;
      // The overlay is not touched: it is a set of on-screen toggles that stay
      // lit across a focus change, and clearing it here would leave the report
      // disagreeing with what the keyboard panel shows.
      record();
    },

    // Latch the on-screen keyboard's modifiers. They are held separately from
    // the physical ones and OR'd in, so a panel latch and a held physical key
    // combine instead of overwriting each other.
    setOverlayModifier(mask) {
      overlay = mask;
      record();
    },

    // The live report, for the keyboard debug readout. Copies so a reader
    // cannot mutate the state machine.
    snapshot() {
      return { held: held.slice(), modifier: modifier | overlay };
    },

    // Publish the next queued state. The run loop calls this once per frame,
    // before it runs the VM, so the OS polls the state that was published for
    // this frame.
    flush() {
      if (queue.length === 0) return;
      published = queue.shift();
      setState(published[0], published[1]);
    },

    // How many states are still waiting. Exposed for tests.
    pending() {
      return queue.length;
    },
  };
}
