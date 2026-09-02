// Page entry: boot the wasm VM, then render the shell around it.
//
// harucom.js (a classic script loaded before this module) defines the global
// createHarucomModule factory. The canvas and the log element are created here
// rather than in index.html because print handlers must be in place before the
// module is constructed, which is earlier than React can mount: output from
// harucom_init would otherwise be lost.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { App } from "./App";
import { createEngine, type HarucomModule } from "./engine";
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
// which emscripten routes to Module.print / printErr one line at a time. This
// runs often and on the same thread as the VM and the canvas blit, so append one
// text node and trim from the front, rather than rebuilding the whole log and
// forcing a layout per line.
const LOG_MAX_LINES = 500;
const log = document.createElement("pre");
log.className = "bg-base text-console font-mono text-xs leading-relaxed h-64 overflow-y-auto m-0 p-2 whitespace-pre-wrap break-all";
let lineCount = 0;

function printLine(text: string) {
  log.appendChild(document.createTextNode(text + "\n"));
  if (++lineCount > LOG_MAX_LINES) {
    log.removeChild(log.firstChild!);
    lineCount--;
  }
  log.scrollTop = log.scrollHeight;
}

const root = createRoot(document.getElementById("app")!);

window.createHarucomModule({ print: printLine, printErr: printLine }).then((module) => {
  const engine = createEngine(module, { canvas });

  // Ctrl-Alt-Delete reboot: the wasm shim (usb_host_wasm.c) calls this when that
  // chord appears in the HID report. The board watchdog_reboots. The browser
  // reloads, which recreates the Module and reruns harucom_init from scratch.
  window.__harucomReboot = () => location.reload();

  // flushSync so the canvas is in the document before the first blit, rather
  // than painting an offscreen node for the first few frames.
  flushSync(() => root.render(<App canvas={canvas} engine={engine} log={log} />));

  try {
    engine.start();
  } catch (e) {
    printLine("harucom: " + (e as Error).message);
  }
}).catch((e: Error) => {
  // A missing or stale harucom.wasm rejects here, before any output exists.
  printLine("harucom: failed to load the wasm module: " + e.message);
  flushSync(() => root.render(<App canvas={canvas} engine={null} log={log} />));
});
