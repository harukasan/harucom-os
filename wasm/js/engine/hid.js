// DOM key -> USB HID usage mapping (pure, DOM-independent).
//
// Maps KeyboardEvent.code to USB HID keyboard usage IDs (the codes a real USB
// keyboard reports) and modifier keys to the HID modifier bitmask, so the
// browser key path matches the board's USB host. This module holds no state and
// touches no DOM, so it is unit-testable under node.

export const HID = {
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

export const MOD = {
  ControlLeft:0x01,ShiftLeft:0x02,AltLeft:0x04,MetaLeft:0x08,
  ControlRight:0x10,ShiftRight:0x20,AltRight:0x40,MetaRight:0x80,
};

// Resolve a DOM key event to a HID usage. Keyed on e.code, but fall back to
// e.key for the space bar: some browsers / IME states report its code as
// something other than "Space", while e.key is always " ". Returns undefined
// when no usage maps.
export function usageFor(e) {
  let u = HID[e.code];
  if (u === undefined && e.key === " ") u = 0x2C;
  return u;
}
