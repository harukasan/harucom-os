// Phase 3 gate: the funicular Shell loads from /_web, mounts in the same VM as
// the OS, renders engine events polled from the bridge, and drives the bridge
// commands from DOM events. The Engine writes the UI sources into MEMFS /_web/lib
// (here read from disk; the browser fetches them) and starts them via
// harucom_run_ruby. window.__harucomBridge is mocked the way the real Engine
// exposes it (stdout lines, keyboard debug, setPad/startAudio commands).
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { boot } = require("./harness.cjs");

describe("funicular Shell from /_web", () => {
  let h;
  const padCalls = [];
  before(async () => {
    h = await boot();
    const { installUI } = await import("../js/engine/ui.js");
    // JS.global resolves to `window` (picoruby-wasm js.c), so expose the bridge
    // there; in the browser window === globalThis, so the Engine sets it there.
    let pending = ["boot: alpha", "boot: bravo"];
    globalThis.window.__harucomBridge = {
      takePrints: () => { const p = pending; pending = []; return p; },
      keyInfo: () => "last key: code=KeyZ",
      setPad: (pad, dir, down) => { padCalls.push([pad, dir, down]); },
      startAudio: () => {},
    };
    // Write every UI source (shell.rb requires the panes), as the browser does.
    const libDir = path.join(__dirname, "../ruby/lib");
    const files = {};
    for (const f of fs.readdirSync(libDir)) {
      if (f.endsWith(".rb")) files["lib/" + f] = fs.readFileSync(path.join(libDir, f), "utf8");
    }
    installUI(h.Module, files);
    h.drive(5000); // run the UI task: require + mount + poll/drain
  });

  it("writes the UI under /_web (visible to the OS by design)", () => {
    const out = h.evalInIRB('p File.exist?("/_web/lib/shell.rb")', "=> ");
    assert.match(out, /=> true/, out);
  });

  it("renders drained stdout lines in the console pane", () => {
    const html = globalThis.document.getElementById("app").innerHTML;
    assert.match(html, /boot: alpha/, html);
    assert.match(html, /boot: bravo/, html);
  });

  it("renders the keyboard debug string", () => {
    const html = globalThis.document.getElementById("app").innerHTML;
    assert.match(html, /code=KeyZ/, html);
  });

  it("renders two D-pads with direction buttons", () => {
    const pads = globalThis.document.querySelectorAll("#app .pad");
    assert.equal(pads.length, 2, "two pads");
    const btns = globalThis.document.querySelectorAll("#app .padbtn");
    assert.equal(btns.length, 8, "four buttons per pad");
  });

  it("calls bridge.setPad on a pad button press", () => {
    const btn = globalThis.document.querySelector("#app .padbtn"); // pad 0, dir UP=1
    btn.dispatchEvent(new globalThis.window.Event("pointerdown"));
    h.drive(300); // the event callback is enqueued on the VM scheduler, not synchronous
    assert.deepEqual(padCalls[0], [0, 1, true], JSON.stringify(padCalls));
  });
});
