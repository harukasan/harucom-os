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
        // Only the primary button. A right-click opens the context menu, which
        // can swallow the matching pointerup and leave the direction latched.
        if (e.button !== 0) return;
        button.setPointerCapture(e.pointerId);
        engine.setPad(pad, dir, true);
        // On a touch device these buttons are the only input, and audio.js only
        // listens on the canvas and the keyboard, so arm from here as well or
        // audio_demo runs silently.
        engine.armAudio();
        e.preventDefault(); // do not steal focus from the screen
      });
      const release = () => engine.setPad(pad, dir, false);
      button.addEventListener("pointerup", release);
      button.addEventListener("pointercancel", release);
      // The context menu can appear without a pointerup reaching the page.
      button.addEventListener("contextmenu", (e) => e.preventDefault());
      el.appendChild(button);
    }
    root.appendChild(el);
  }
  // Losing the page can swallow the release entirely. Switching apps on a phone
  // fires visibilitychange without a window blur, so watch both, as the
  // keyboard does.
  const releaseAll = () => engine.releasePads();
  window.addEventListener("blur", releaseAll);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) releaseAll();
  });
}
