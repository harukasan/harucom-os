// On-screen D-pad -> resistor-ladder ADC value (pure, DOM-independent).
//
// The board has two resistor-ladder pads read over ADC (Board::Pad). A pressed
// set of directions is converted to the ADC value the ladder would produce
// (parallel resistance), matching Board::Pad's calibration table so its decode
// returns the right buttons. No state, no DOM, so this is unit-testable.

export const PAD_CAL = [2000, 2760, 3300, 3646]; // single RIGHT/UP/DOWN/LEFT raw
export const PAD_G = PAD_CAL.map((c) => 4095 / c - 1);

// Convert a direction bitmask (bit i = direction i pressed) to the raw ADC value
// the resistor ladder produces. An empty mask reads idle (pulled to 3V3).
export function padRawValue(mask) {
  if (!mask) return 4095; // idle: pulled to 3V3
  let s = 0;
  for (let i = 0; i < 4; i++) if (mask & (1 << i)) s += PAD_G[i];
  return Math.round(4095 / (s + 1));
}
