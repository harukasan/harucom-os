// Engine facade: the single window onto the wasm runtime and its devices.
//
// createEngine wraps an already-created emscripten Module and composes the
// device modules (display, keyboard, audio, pads, run loop). start() then inits
// the VM, prunes the runtime-only dirs, and starts the run loop. The shell
// drives it through this surface and never touches Module._harucom_* directly.
//
// Readings flow out through on(event, callback):
//   "keys"  a one-line keyboard readout after each DOM key event
//   "frame" the DVI frame count, each time it advances
//   "audio" { level, underruns, dropped }, once a second
// Console output does not go through the bus. It starts before the engine
// exists, so it is buffered by a console log the caller creates first and hands
// in (see createConsoleLog).
//
// The filesystem is reached through engine.files rather than the shell calling
// into MEMFS: the path checks that keep a dropped name inside the chosen
// directory belong with the machine, not with the panel that draws the list.

import { createEventBus } from "./events.js";
import { createDisplay } from "./display.js";
import { createKeyReport } from "./key-report.js";
import { installKeyboard } from "./keyboard.js";
import { installAudio } from "./audio.js";
import { createPads } from "./pads.js";
import { startRunLoop } from "./runloop.js";
import { addFiles } from "./files.js";
import { pruneRuntimeDirs, readFileBytes, readTree } from "./fs.js";

export function createEngine(Module, { canvas, log = null }) {
  const bus = createEventBus();
  const waiting = [];   // onReady callbacks registered before start()
  let ready = false;

  // None of these touch the VM yet (createDisplay only reads the static
  // framebuffer address and the constant dimensions), so composing them before
  // start() is safe, and the shell can subscribe before the VM prints anything.
  const display = createDisplay(Module, canvas);
  // One report state machine, shared by the physical keyboard and the on-screen
  // one, so a panel key and a held physical key produce one coherent report.
  const report = createKeyReport((modifier, codes) =>
    Module._harucom_kbd_set_state(modifier,
      codes[0]||0, codes[1]||0, codes[2]||0, codes[3]||0, codes[4]||0, codes[5]||0));
  installKeyboard(canvas, report, { onDebug: (text) => bus.emit("keys", text) });
  // Web Audio needs a user gesture, so this only arms the listeners here.
  const audio = installAudio(Module, canvas, { onDiag: (diag) => bus.emit("audio", diag) });
  const pads = createPads(Module);

  let started = false;
  // Init the VM, drop the emscripten-only dirs, and start the run loop. Throws
  // if harucom_init fails.
  function start() {
    if (started) return;
    started = true;
    if (Module._harucom_init() !== 0) throw new Error("harucom_init failed");
    pruneRuntimeDirs(Module); // drop the emscripten-only /home /tmp /proc dirs
    // Ready means the filesystem is the one the OS will use, which is true from
    // here: it does not depend on the run loop, and tying it to that would hide
    // a working filesystem behind an unrelated failure.
    ready = true;
    for (const callback of waiting.splice(0)) callback();
    startRunLoop(Module, {
      blit: display.blit,
      flushKeys: report.flush,
      pump: audio.pump,
      onFrame: (frame) => bus.emit("frame", frame),
    });
  }

  // Run `callback` once the VM is up and the rootfs is on MEMFS, immediately if
  // that has already happened.
  //
  // This is not an event, because it cannot be missed. The shell is rendered
  // before start() so the canvas is in the document for the first blit, which
  // means anything reading the filesystem mounts while MEMFS still holds only
  // the embedded dictionary. Whether its subscription is in place before start()
  // then depends on when React flushes effects, and a missed notification would
  // leave a listing that is wrong for the whole session.
  function onReady(callback) {
    if (ready) {
      callback();
      return () => {};
    }
    waiting.push(callback);
    return () => {
      const i = waiting.indexOf(callback);
      if (i >= 0) waiting.splice(i, 1);
    };
  }

  return {
    start,
    onReady,
    on: bus.on,
    log,
    setPad: pads.setPad,
    releasePads: pads.releaseAll,
    // Any gesture can arm audio. The canvas and the keyboard do it themselves,
    // but the on-screen pads are the only input on a touch device, so the shell
    // has to arm from them too.
    armAudio: audio.arm,
    // The on-screen keyboard drives the same report as the physical one.
    keyDown: report.keyDown,
    keyUp: report.keyUp,
    setKeyModifier: report.setOverlayModifier,
    files: {
      add: (directory, files) => addFiles(Module, directory, files),
      tree: () => readTree(Module),
      read: (path) => readFileBytes(Module, path),
    },
  };
}
