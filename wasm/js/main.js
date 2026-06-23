// Entry point: boot the wasm VM and wire the Engine facade to the static chrome.
//
// harucom.js (loaded as a classic script before this module) defines the global
// createHarucomModule factory. We create the Module, hand it to createEngine
// (which composes the device modules), bind the engine's events and commands to
// the current static DOM (#out / #kbddbg / #pads), then start it (start() inits
// the VM, so we subscribe to "print" first to catch init-time output). This is a
// thin composition root; Phase 3 swaps the static DOM for a funicular Shell
// without changing the Engine.

import { createEngine } from "./engine/index.js";
import { installPadDom } from "./engine/pads.js";

const outEl = document.getElementById("out");

// stdout / stderr arrive via the posix hal_write() (emscripten fd 1 / 2), which
// emscripten routes to Module.print / Module.printErr. Those handlers must be set
// at construction time, so they forward into the engine once it exists.
let engine;
window.createHarucomModule({
  print: (s) => engine?.print(s + "\n"),
  printErr: (s) => engine?.print(s + "\n"),
}).then((Module) => {
  const canvas = document.getElementById("screen");
  engine = createEngine(Module, { canvas });

  engine.on("print", (line) => { outEl.textContent += line; });

  const kbddbgEl = document.getElementById("kbddbg");
  if (kbddbgEl) engine.on("keys", (text) => { kbddbgEl.textContent = text; });

  installPadDom(document.getElementById("pads"),
    { setPad: engine.setPad, startAudio: engine.startAudio });

  // start() inits the VM; subscribers above are already attached, so init-time
  // stdout/stderr reaches #out. It throws if harucom_init fails.
  try {
    engine.start();
  } catch (e) {
    outEl.textContent += "\n[" + e.message + "]\n";
  }
});
