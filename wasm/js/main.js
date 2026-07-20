// Entry point: boot the wasm VM, wire the Engine to a JS bridge, and start the
// funicular UI.
//
// harucom.js (loaded as a classic script before this module) defines the global
// createHarucomModule factory. We create the Module, hand it to createEngine
// (which composes the device modules), expose an Engine <-> UI bridge on the
// window, start the VM, then write the funicular UI sources into MEMFS /_web and
// run them. The App (Screen + a tabbed Panels dock) renders the chrome; the
// canvas (#screen) is an Engine-owned leaf the Screen panel adopts.
//
// The UI source list is data-driven: rake stage writes ruby/manifest.json by
// globbing wasm/ruby/lib, so adding a panel file needs no change here.

import { createEngine } from "./engine/index.js";
import { createBridge } from "./engine/bridge.js";
import { installUI, startUI } from "./engine/ui.js";

// Fetch the manifest (the files to stage and the panel modules to require).
async function fetchManifest() {
  const res = await fetch("ruby/manifest.json");
  return res.json(); // { files: ["lib/..."], panels: ["console_panel", ...] }
}

async function fetchFiles(fileList) {
  const files = {};
  for (const rel of fileList) {
    const res = await fetch("ruby/" + rel);
    files[rel] = await res.text();
  }
  return files;
}

// stdout / stderr arrive via the posix hal_write() (emscripten fd 1 / 2), which
// emscripten routes to Module.print / Module.printErr per line (no trailing
// newline). Those handlers must be set at construction time, so they forward
// each bare line into the engine once it exists; the ConsolePanel joins lines
// with newlines itself, so adding one here would double-space the console.
let engine;
window.createHarucomModule({
  print: (s) => engine?.print(s),
  printErr: (s) => engine?.print(s),
}).then(async (Module) => {
  const canvas = document.getElementById("screen");
  engine = createEngine(Module, { canvas });

  // Expose the bridge before start() so init-time prints buffer into it (the
  // Engine drains them once the UI mounts). JS.global is window in picoruby-wasm.
  window.__harucomBridge = createBridge(engine);

  // Ctrl-Alt-Delete reboot: the wasm shim (usb_host_wasm.c) calls this when that
  // chord appears in the HID report. The board watchdog_reboots; the browser
  // reloads, which recreates the Module and reruns harucom_init from scratch.
  window.__harucomReboot = () => location.reload();

  // Fetch the UI sources before starting, so the run loop is free to schedule the
  // UI task right after start.
  const manifest = await fetchManifest();
  const files = await fetchFiles(manifest.files);

  try {
    engine.start();                       // inits the VM (global_mrb) and run loop
    installUI(Module, files);             // write /_web/lib
    startUI(Module, { panels: manifest.panels }); // load shell + boot the App
  } catch (e) {
    console.error("harucom:", e.message);
  }
});
