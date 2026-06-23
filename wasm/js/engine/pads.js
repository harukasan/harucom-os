// ADC pads: D-pad direction state -> resistor-ladder value -> wasm.
//
// The board has two resistor-ladder pads read over ADC (Board::Pad). The
// pad-ladder math (padRawValue) lives in pad-ladder.js (pure, testable). createPads
// owns the per-pad pressed mask and pushes the decoded ADC value to wasm; it is
// the single source of pad state. installPadDom builds the on-screen D-pads and
// drives createPads' setPad (Phase 3 replaces the DOM with a funicular Pads
// component that calls the same setPad).

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

// Build the on-screen D-pads under padsEl and drive setPad from their press
// state. startAudio is invoked on a press so a pad tap also satisfies the audio
// user-gesture requirement.
export function installPadDom(padsEl, { setPad, startAudio }) {
  if (!padsEl) return;

  // dir constants: RIGHT=0, UP=1, DOWN=2, LEFT=3; arranged as a cross.
  const LAYOUT = [
    { label: "↑", dir: 1, col: 2, row: 1 }, // up
    { label: "←", dir: 3, col: 1, row: 2 }, // left
    { label: "→", dir: 0, col: 3, row: 2 }, // right
    { label: "↓", dir: 2, col: 2, row: 3 }, // down
  ];
  for (let pad = 0; pad < 2; pad++) {
    const grid = document.createElement("div");
    grid.className = "pad";
    const title = document.createElement("div");
    title.className = "pad-title";
    title.textContent = "PAD" + pad;
    grid.appendChild(title);
    LAYOUT.forEach((b) => {
      const btn = document.createElement("button");
      btn.className = "padbtn";
      btn.textContent = b.label;
      btn.style.gridColumn = String(b.col);
      btn.style.gridRow = String(b.row + 1); // row 1 is the title
      const press = (e) => {
        e.preventDefault();
        startAudio(); // a pad tap is a user gesture too
        setPad(pad, b.dir, true);
        btn.classList.add("on");
      };
      const release = (e) => {
        e.preventDefault();
        setPad(pad, b.dir, false);
        btn.classList.remove("on");
      };
      btn.addEventListener("pointerdown", press);
      btn.addEventListener("pointerup", release);
      btn.addEventListener("pointerleave", release);
      btn.addEventListener("pointercancel", release);
      grid.appendChild(btn);
    });
    padsEl.appendChild(grid);
  }
}
