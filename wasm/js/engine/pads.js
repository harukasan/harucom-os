// ADC pads: D-pad direction state -> resistor-ladder value -> wasm.
//
// The board reads two resistor-ladder pads over ADC (Board::Pad). The ladder
// math lives in pad-ladder.js (pure, testable). This owns the per-pad pressed
// mask and writes the value the ladder would produce to the wasm ADC shim, so
// Board::Pad decodes it exactly as it decodes the real hardware. The on-screen
// buttons that drive it are page chrome and live in js/pad-ui.js.
import { padRawValue } from "./pad-ladder.js";

export function createPads(Module) {
  const padMask = [0, 0];
  function setPad(pad, dir, down) {
    // A shift count out of range wraps in JS, so an unchecked direction would
    // press a button the user never touched, or leave the mask permanently
    // non-zero so the pad never reads idle again.
    if (pad !== 0 && pad !== 1) return;
    if (dir < 0 || dir > 3) return;
    if (down) padMask[pad] |= (1 << dir);
    else padMask[pad] &= ~(1 << dir);
    Module._harucom_pad_set(pad, padRawValue(padMask[pad]));
  }
  // Release everything, for a pointer lost outside a button or a page blur,
  // where the up event never arrives and a direction would stay latched.
  function releaseAll() {
    for (let pad = 0; pad < 2; pad++) {
      padMask[pad] = 0;
      Module._harucom_pad_set(pad, padRawValue(0));
    }
  }
  return { setPad, releaseAll };
}
