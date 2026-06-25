// Entry point: boot the wasm VM, wire the Engine to a JS bridge, and start the
// funicular Shell.
//
// harucom.js (loaded as a classic script before this module) defines the global
// createHarucomModule factory. We create the Module, hand it to createEngine
// (which composes the device modules), expose an Engine <-> Shell bridge on the
// window, start the VM, then write the funicular UI sources into MEMFS /_web and
// run them. The Shell (Console / KbdDebug / Pads) renders the chrome; the canvas
// (#screen) stays an Engine-owned sibling of the Shell container (#app).

import { createEngine } from "./engine/index.js";
import { createBridge } from "./engine/bridge.js";
import { installUI } from "./engine/ui.js";

// The funicular UI sources to load into /_web (fetched relative to the page).
// shell.rb is the entry (loaded by ui.js); it requires the panes, so they must
// be present in /_web/lib too. Order does not matter (all are written first).
const UI_FILES = [
  "lib/shell.rb",
  "lib/console_pane.rb",
  "lib/kbd_debug.rb",
  "lib/pads.rb",
];

async function fetchUI() {
  const files = {};
  for (const rel of UI_FILES) {
    const res = await fetch("ruby/" + rel);
    files[rel] = await res.text();
  }
  return files;
}

// stdout / stderr arrive via the posix hal_write() (emscripten fd 1 / 2), which
// emscripten routes to Module.print / Module.printErr per line (no trailing
// newline). Those handlers must be set at construction time, so they forward
// each bare line into the engine once it exists; the ConsolePane joins lines
// with newlines itself, so adding one here would double-space the console.
let engine;
window.createHarucomModule({
  print: (s) => engine?.print(s),
  printErr: (s) => engine?.print(s),
}).then(async (Module) => {
  const canvas = document.getElementById("screen");
  engine = createEngine(Module, { canvas });

  // Expose the bridge before start() so init-time prints buffer into it (the
  // Shell drains them once it mounts). JS.global is window in picoruby-wasm.
  window.__harucomBridge = createBridge(engine);

  // Fetch the UI sources before starting, so the run loop is free to schedule the
  // UI task right after start.
  const files = await fetchUI();

  try {
    engine.start();          // inits the VM (global_mrb) and the run loop
    installUI(Module, files); // write /_web/lib + enqueue the shell task
  } catch (e) {
    console.error("harucom:", e.message);
  }
});
