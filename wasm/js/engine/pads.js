// ADC pads: D-pad direction state -> resistor-ladder value -> wasm.
//
// The board has two resistor-ladder pads read over ADC (Board::Pad). The
// pad-ladder math (padRawValue) lives in pad-ladder.js (pure, testable). createPads
// owns the per-pad pressed mask and pushes the decoded ADC value to wasm; it is
// the single source of pad state. The on-screen D-pads are drawn by the funicular
// PadsPanel, which calls setPad through the Engine bridge.

import { padRawValue } from "./pad-ladder.js";

// Own the pad state. Returns { setPad(pad, dir, down) } that updates the pressed
// mask and writes the ladder's raw ADC value to the wasm pad shim.
export function createPads(Module) {
  const padMask = [0, 0];
  function setPad(pad, dir, down) {
    if (down) padMask[pad] |= (1 << dir);
    else padMask[pad] &= ~(1 << dir);
    Module._harucom_pad_set(pad, padRawValue(padMask[pad]));
  }
  return { setPad };
}
