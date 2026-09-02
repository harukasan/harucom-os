// Entry point: boot the wasm VM and wire it to the page.
//
// harucom.js (loaded as a classic script before this module) defines the global
// createHarucomModule factory. We create the Module, hand it to createEngine
// (which composes the device modules), then start the VM. The OS paints the
// #screen canvas. stdout and stderr go to the #log element below it.

import { createEngine } from "./engine/index.js";
import { installPadUI } from "./pad-ui.js";

const log = document.getElementById("log");

// stdout / stderr arrive via the posix hal_write() (emscripten fd 1 / 2), which
// emscripten routes to Module.print / Module.printErr per line (no trailing
// newline). Those handlers must be set at construction time, so init-time output
// is captured before the engine exists.
// The console mirrors every line the OS prints to fd 1, so this runs often and
// on the same thread as the VM and the canvas blit. Append one text node and
// trim from the front only when the cap is exceeded, rather than rebuilding the
// whole log and forcing a layout on each line.
const LOG_MAX_LINES = 500;
let lineCount = 0;

function printLine(text) {
  log.appendChild(document.createTextNode(text + "\n"));
  if (++lineCount > LOG_MAX_LINES) {
    log.removeChild(log.firstChild);
    lineCount--;
  }
  log.scrollTop = log.scrollHeight;
}

window.createHarucomModule({ print: printLine, printErr: printLine }).then((Module) => {
  const engine = createEngine(Module, { canvas: document.getElementById("screen") });

  // Ctrl-Alt-Delete reboot: the wasm shim (usb_host_wasm.c) calls this when that
  // chord appears in the HID report. The board watchdog_reboots. The browser
  // reloads, which recreates the Module and reruns harucom_init from scratch.
  window.__harucomReboot = () => location.reload();

  installPadUI(document.getElementById("pads"), engine);

  try {
    engine.start();
  } catch (e) {
    printLine("harucom: " + e.message);
  }
}).catch((e) => {
  // A missing or stale harucom.wasm rejects here, before any output exists.
  printLine("harucom: failed to load the wasm module: " + e.message);
});
