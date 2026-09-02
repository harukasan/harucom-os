// On-screen D-pads.
//
// The board has two 4-way pads wired as resistor ladders. The browser has no
// ADC, so these buttons stand in for them: pressing one tells the engine which
// direction is down, and the engine writes the value the ladder would produce.
//
// This is page chrome, not a device, which is why it lives outside engine/. It
// only calls engine.setPad.

const DIRECTIONS = [
  { dir: 1, label: "▲", area: "up" },     // UP
  { dir: 3, label: "◀", area: "left" },   // LEFT
  { dir: 0, label: "▶", area: "right" },  // RIGHT
  { dir: 2, label: "▼", area: "down" },   // DOWN
];

// Build both pads into `root` and wire them to the engine.
export function installPadUI(root, engine) {
  for (let pad = 0; pad < 2; pad++) {
    const el = document.createElement("div");
    el.className = "pad";
    el.setAttribute("aria-label", pad === 0 ? "Left pad" : "Right pad");
    for (const { dir, label, area } of DIRECTIONS) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = label;
      button.style.gridArea = area;
      // Pointer capture keeps the release on this button even if the finger
      // slides off, so a direction cannot stay latched.
      button.addEventListener("pointerdown", (e) => {
        button.setPointerCapture(e.pointerId);
        engine.setPad(pad, dir, true);
        e.preventDefault(); // do not steal focus from the screen
      });
      const release = () => engine.setPad(pad, dir, false);
      button.addEventListener("pointerup", release);
      button.addEventListener("pointercancel", release);
      el.appendChild(button);
    }
    root.appendChild(el);
  }
  // A page blur can swallow the release entirely.
  window.addEventListener("blur", () => engine.releasePads());
}
