// Phase 3 gate: the funicular Shell loads from /_web, mounts in the same VM as
// the OS, and renders engine events polled from the bridge. The Engine writes the
// UI sources into MEMFS /_web/lib (here read from disk; the browser fetches them)
// and starts them via harucom_run_ruby. window.__harucomBridge is mocked here the
// way the real Engine would expose it (stdout lines, keyboard debug).
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { boot } = require("./harness.cjs");

describe("funicular Shell from /_web", () => {
  let h;
  before(async () => {
    h = await boot();
    const { installUI } = await import("../js/engine/ui.js");
    // Mock the engine bridge: hand the Shell two stdout lines (once, like a real
    // drain) and a keyboard debug string.
    // JS.global resolves to `window` (picoruby-wasm js.c), so expose the bridge
    // there; in the browser window === globalThis, so the Engine sets it there.
    let pending = ["boot: alpha", "boot: bravo"];
    globalThis.window.__harucomBridge = {
      takePrints: () => { const p = pending; pending = []; return p; },
      keyInfo: () => "last key: code=KeyZ",
    };
    const src = fs.readFileSync(path.join(__dirname, "../ruby/lib/shell.rb"), "utf8");
    installUI(h.Module, { "lib/shell.rb": src });
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
});
