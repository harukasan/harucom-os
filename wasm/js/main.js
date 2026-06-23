// Entry point: boot the wasm VM and wire up the browser modules.
//
// harucom.js (loaded as a classic script before this module) defines the global
// createHarucomModule factory. We create the module, init the VM, then hand it to
// the display / keyboard / audio / pad modules and start the run loop.

import { createDisplay } from "./display.js";
import { installKeyboard } from "./keyboard.js";
import { installAudio } from "./audio.js";
import { installPads } from "./pads.js";
import { startRunLoop } from "./runloop.js";
import { pruneRuntimeDirs } from "./fs.js";

const outEl = document.getElementById("out");
const append = (s) => { outEl.textContent += s; };

// stdout / stderr arrive via the posix hal_write() (emscripten fd 1 / 2), which
// emscripten routes to Module.print / Module.printErr.
window.createHarucomModule({
  print: (s) => append(s + "\n"),
  printErr: (s) => append(s + "\n"),
}).then((Module) => {
  if (Module._harucom_init() !== 0) {
    append("\n[harucom_init failed]\n");
    return;
  }
  pruneRuntimeDirs(Module); // drop the emscripten-only /home /tmp /proc dirs

  const canvas = document.getElementById("screen");
  const display = createDisplay(Module, canvas);
  const keyboard = installKeyboard(Module, canvas, document.getElementById("kbddbg"));
  const audio = installAudio(Module, canvas);
  installPads(Module, document.getElementById("pads"), audio.startAudio);

  startRunLoop(Module, {
    blit: display.blit,
    applyReleases: keyboard.applyReleases,
    pump: audio.pump,
  });
});
