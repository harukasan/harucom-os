// Engine facade: the single window onto the wasm runtime and its devices.
//
// createEngine wraps an already-created emscripten Module and composes the
// device modules (display, keyboard, run loop). start() then inits the VM,
// prunes the runtime-only dirs, and starts the run loop. The page drives it
// through this surface and never touches Module._harucom_* directly.

import { createDisplay } from "./display.js";
import { createKeyReport } from "./key-report.js";
import { installKeyboard } from "./keyboard.js";
import { startRunLoop } from "./runloop.js";
import { pruneRuntimeDirs } from "./fs.js";

export function createEngine(Module, { canvas }) {
  // None of these touch the VM yet (createDisplay only reads the static
  // framebuffer address and the constant dimensions), so composing them before
  // start() is safe.
  const display = createDisplay(Module, canvas);
  const report = createKeyReport((modifier, codes) =>
    Module._harucom_kbd_set_state(modifier,
      codes[0]||0, codes[1]||0, codes[2]||0, codes[3]||0, codes[4]||0, codes[5]||0));
  installKeyboard(canvas, report);

  let started = false;
  // Init the VM, drop the emscripten-only dirs, and start the run loop. Throws
  // if harucom_init fails.
  function start() {
    if (started) return;
    started = true;
    if (Module._harucom_init() !== 0) throw new Error("harucom_init failed");
    pruneRuntimeDirs(Module); // drop the emscripten-only /home /tmp /proc dirs
    startRunLoop(Module, { blit: display.blit, applyReleases: report.applyReleases });
  }

  return { canvas, start };
}
