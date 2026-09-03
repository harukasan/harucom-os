// Page entry: boot the wasm VM, then render the shell around it.
//
// harucom.js (a classic script loaded before this module) defines the global
// createHarucomModule factory. The canvas and the console buffer are created
// here rather than in index.html because the print handlers must be in place
// before the module is constructed, which is earlier than React can mount:
// output from harucom_init would otherwise be lost.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { App } from "./App";
import { createConsoleLog, createEngine, type HarucomModule } from "./engine";
import "./index.css";

declare global {
  interface Window {
    createHarucomModule(options: object): Promise<HarucomModule>;
    __harucomReboot?: () => void;
  }
}

const canvas = document.createElement("canvas");
canvas.id = "screen"; // index.css sizes it and keeps the pixels crisp
canvas.width = 640;
canvas.height = 480;

// stdout and stderr arrive via the posix hal_write() (emscripten fd 1 and 2),
// which emscripten routes to Module.print / printErr one line at a time. The
// buffer is created before the module because emscripten captures these handlers
// at construction, and harucom_init prints before anything can be mounted.
const log = createConsoleLog();

const root = createRoot(document.getElementById("app")!);

window.createHarucomModule({ print: log.write, printErr: log.write }).then((module) => {
  const engine = createEngine(module, { canvas, log });

  // Ctrl-Alt-Delete reboot: the wasm shim (usb_host_wasm.c) calls this when that
  // chord appears in the HID report. The board watchdog_reboots. The browser
  // reloads, which recreates the Module and reruns harucom_init from scratch.
  window.__harucomReboot = () => location.reload();

  // flushSync so the canvas is in the document before the first blit, rather
  // than painting an offscreen node for the first few frames.
  flushSync(() => root.render(<App canvas={canvas} engine={engine} log={log} />));

  // installKeyboard already asked for focus, but it runs inside createEngine,
  // while the canvas is still detached and focus() does nothing. Keys reach the
  // OS regardless (keyboard.js listens on window), but the canvas is the focus
  // target the shell sets up, so give it focus now that it is on the page.
  canvas.focus();

  try {
    engine.start();
  } catch (e) {
    log.write("harucom: " + (e as Error).message);
  }
}).catch((e: Error) => {
  // A missing or stale harucom.wasm rejects here, before any output exists.
  log.write("harucom: failed to load the wasm module: " + e.message);
  flushSync(() => root.render(<App canvas={canvas} engine={null} log={log} />));
});
