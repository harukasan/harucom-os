// Loads the built shell bundle (build/wasm/ui/main.js) in a jsdom page.
//
// The React sources have their own unit tests (rake wasm:ui_test), which run
// against the TypeScript. This one runs against the artifact the browser
// actually fetches, so it catches the ways a build can be wrong while every
// source test still passes: a bundle that throws on load, a page that never
// mounts, an entry that does not find #app.
//
// The module factory is stubbed to reject, which is the one path that needs no
// canvas 2D context (jsdom has none without node-canvas). That still proves the
// bundle parses, React mounts, the canvas is hosted and the log is adopted.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");
const { JSDOM } = require("jsdom");

const BUNDLE = path.join(__dirname, "..", "..", "build", "wasm", "ui", "main.js");

describe("shell bundle", () => {
  let document;

  before(async () => {
    assert.ok(fs.existsSync(BUNDLE), `${BUNDLE} not found. Run \`rake wasm:build\` first.`);
    const dom = new JSDOM('<!DOCTYPE html><div id="app"></div>', { pretendToBeVisual: true });
    globalThis.window = dom.window;
    globalThis.document = document = dom.window.document;
    globalThis.navigator = dom.window.navigator;
    globalThis.HTMLElement = dom.window.HTMLElement;
    dom.window.createHarucomModule = () => Promise.reject(new Error("stubbed"));

    await import(pathToFileURL(BUNDLE).href);
    // React renders in a microtask even under flushSync's caller, so let the
    // rejection handler and the mount both settle.
    await new Promise((resolve) => setTimeout(resolve, 50));
  });

  it("mounts into #app", () => {
    assert.ok(document.getElementById("app").firstElementChild, document.body.innerHTML);
  });

  it("hosts the screen canvas inside the shell", () => {
    const canvas = document.querySelector("#app canvas#screen");
    assert.ok(canvas, "the canvas is inside the mounted shell: " + document.body.innerHTML);
    assert.equal(canvas.width, 640);
    assert.equal(canvas.height, 480);
  });

  it("reports a failed module load in the log rather than dying silently", () => {
    assert.match(document.querySelector("#app pre").textContent, /failed to load the wasm module/);
  });
});

// The same bundle, but with a module that answers instead of rejecting. This is
// the wiring the failure path never reaches: the engine composed, the panel host
// rendered, and a panel command arriving at the module. The VM is not booted
// (driving it through requestAnimationFrame would take seconds of wall clock),
// so the stub answers the handful of calls composing an engine makes.
describe("shell bundle, with a module that loads", () => {
  let document, module;

  function stubModule() {
    const calls = [];
    const record = (name) => (...args) => { calls.push([name, ...args]); return 0; };
    return {
      calls,
      HEAPU8: new Uint8Array(640 * 480 + 64),
      HEAPF32: new Float32Array(4096),
      _malloc: () => 64,
      _free: () => {},
      _harucom_init: () => 0,
      _harucom_dvi_width: () => 640,
      _harucom_dvi_height: () => 480,
      _harucom_dvi_framebuffer: () => 64,
      _harucom_dvi_frame_count: () => 0,
      _harucom_audio_sample_rate: () => 50000,
      _harucom_audio_pull: () => 0,
      _harucom_kbd_set_state: record("kbd"),
      _harucom_pad_set: record("pad"),
      _mrb_run_step: () => 0,
      _mrb_tick_wasm: () => 0,
      FS: { mkdir() {}, unlink() {}, rmdir() {}, readdir: () => [], analyzePath: () => ({ exists: false }) },
    };
  }

  before(async () => {
    const dom = new JSDOM('<!DOCTYPE html><div id="app"></div>', { pretendToBeVisual: true });
    globalThis.window = dom.window;
    globalThis.document = document = dom.window.document;
    globalThis.navigator = dom.window.navigator;
    globalThis.HTMLElement = dom.window.HTMLElement;
    // jsdom has no 2D context. The display only needs somewhere to build and put
    // an ImageData, so a stub is enough to compose the engine.
    // jsdom has no pointer capture. The pads take it so a press that slides off
    // a button still releases, and without this the handler throws before it
    // reaches the engine.
    dom.window.Element.prototype.setPointerCapture = () => {};
    dom.window.Element.prototype.releasePointerCapture = () => {};
    dom.window.HTMLCanvasElement.prototype.getContext = () => ({
      createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }),
      putImageData: () => {},
    });
    module = stubModule();
    dom.window.createHarucomModule = () => Promise.resolve(module);

    // The bundle runs its side effects on first import, and node caches modules
    // by URL, so ask for a distinct one to get a second, independent boot.
    await import(pathToFileURL(BUNDLE).href + "?withModule");
    await new Promise((resolve) => setTimeout(resolve, 50));
  });

  it("renders the panel host once the engine is up", () => {
    const tabs = [...document.querySelectorAll("#app button")].map((b) => b.textContent);
    for (const title of ["Console", "Keys", "Keyboard", "Pads", "Status"]) {
      assert.ok(tabs.includes(title), `${title} is a tab: ${tabs.join(", ")}`);
    }
  });

  it("drives the module from a panel", async () => {
    const pads = [...document.querySelectorAll("#app button")].find((b) => b.textContent === "Pads");
    pads.dispatchEvent(new document.defaultView.MouseEvent("click", { bubbles: true }));
    // React commits the tab switch after the event, not during it.
    await new Promise((resolve) => setTimeout(resolve, 20));
    const up = document.querySelector('#app button[aria-label="PAD0 up"]');
    assert.ok(up, "the pads panel is showing: " + document.querySelector("#app").innerHTML.slice(0, 300));
    up.dispatchEvent(new document.defaultView.PointerEvent("pointerdown", { bubbles: true, button: 0, pointerId: 1 }));
    assert.ok(module.calls.some(([name]) => name === "pad"), JSON.stringify(module.calls));
  });
});
