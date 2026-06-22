// ADC pads: on-screen D-pads -> resistor-ladder value -> wasm.
//
// The board has two resistor-ladder pads read over ADC (Board::Pad). Each
// on-screen D-pad button maps to a direction; the pressed set is converted to
// the ADC value the ladder would produce (parallel resistance), matching
// Board::Pad's calibration table so its decode returns the right buttons.

const PAD_CAL = [2000, 2760, 3300, 3646]; // single RIGHT/UP/DOWN/LEFT raw
const PAD_G = PAD_CAL.map((c) => 4095 / c - 1);

function padRaw(mask) {
  if (!mask) return 4095; // idle: pulled to 3V3
  let s = 0;
  for (let i = 0; i < 4; i++) if (mask & (1 << i)) s += PAD_G[i];
  return Math.round(4095 / (s + 1));
}

// Build the on-screen D-pads under padsEl and feed their state to the wasm ADC
// shim. startAudio is invoked on a press so a pad tap also satisfies the audio
// user-gesture requirement.
export function installPads(Module, padsEl, startAudio) {
  if (!padsEl) return;

  const padMask = [0, 0];
  function setPadButton(pad, dir, down) {
    if (down) padMask[pad] |= (1 << dir);
    else padMask[pad] &= ~(1 << dir);
    Module._harucom_pad_set(pad, padRaw(padMask[pad]));
  }

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
        setPadButton(pad, b.dir, true);
        btn.classList.add("on");
      };
      const release = (e) => {
        e.preventDefault();
        setPadButton(pad, b.dir, false);
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
