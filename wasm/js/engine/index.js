// Engine facade: the single window onto the wasm runtime and its devices.
//
// createEngine wraps an already-created emscripten Module and composes the
// device modules (display, keyboard, audio, pads, run loop). start() then inits
// the VM, prunes the runtime-only dirs, and starts the run loop. Callers (the
// Shell) drive it through a small command surface and subscribe to events,
// never touching Module._harucom_* directly.
//
// Commands: start() / setPad(pad, dir, down) / startAudio() / print(line) /
// keyDown(usage) / keyUp(usage) / setKeyModifier(mask) (the on-screen keyboard).
// Events (via on): "print" (a stdout/stderr line), "frame" (DVI frame count),
// "audio" ({ level, underruns }), "keys" (keyboard debug string).
//
// print is duplex: Module.print can only be installed at module-construction
// time (emscripten captures it then), so the caller wires Module.print to
// engine.print(line), which the engine re-emits as the "print" event.

import { createEventBus } from "./events.js";
import { createDisplay } from "./display.js";
import { createKeyReport } from "./key-report.js";
import { installKeyboard } from "./keyboard.js";
import { installAudio } from "./audio.js";
import { createPads } from "./pads.js";
import { startRunLoop } from "./runloop.js";
import { pruneRuntimeDirs } from "./fs.js";

export function createEngine(Module, { canvas }) {
  const bus = createEventBus();

  // Compose the device modules. None of these touch the VM yet (createDisplay
  // only reads the static framebuffer address and constant dimensions), so the
  // caller can subscribe to events before start() runs _harucom_init. That
  // ordering matters: init prints to stderr (e.g. "rootfs: deployed N files"),
  // and those lines must reach a "print" subscriber.
  const display = createDisplay(Module, canvas);
  // The HID report state machine, shared by the physical keyboard (installKeyboard)
  // and the on-screen keyboard panel (keyDown/keyUp/setKeyModifier below).
  const report = createKeyReport((modifier, codes) =>
    Module._harucom_kbd_set_state(modifier,
      codes[0]||0, codes[1]||0, codes[2]||0, codes[3]||0, codes[4]||0, codes[5]||0));
  installKeyboard(canvas, report, { onDebug: (text) => bus.emit("keys", text) });
  const audio = installAudio(Module, canvas, {
    onDiag: (diag) => bus.emit("audio", diag),
  });
  const pads = createPads(Module);

  let started = false;
  // Init the VM, drop the emscripten-only dirs, and start the run loop. Throws
  // if harucom_init fails. Call after subscribing to "print" so init-time
  // stdout/stderr is captured.
  function start() {
    if (started) return;
    started = true;
    if (Module._harucom_init() !== 0) throw new Error("harucom_init failed");
    pruneRuntimeDirs(Module); // drop the emscripten-only /home /tmp /proc dirs
    startRunLoop(Module, {
      blit: display.blit,
      applyReleases: report.applyReleases,
      pump: audio.pump,
      onFrame: (frame) => bus.emit("frame", frame),
    });
  }

  return {
    canvas,
    start,
    setPad: pads.setPad,
    startAudio: audio.startAudio,
    keyDown: report.keyDown,
    keyUp: report.keyUp,
    setKeyModifier: report.setOverlayModifier,
    on: bus.on,
    print: (line) => bus.emit("print", line),
  };
}
