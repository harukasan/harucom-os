// Phase 4 gate: the funicular App loads from /_web, mounts in the same VM as the
// OS, builds a tab per self-registered Panel, renders engine state polled through
// the Engine facade, and drives bridge commands from DOM events. The Engine
// writes the UI sources into MEMFS /_web/lib (here read from disk; the browser
// fetches them) and boots them via harucom_run_ruby. window.__harucomBridge is
// mocked the way the real bridge exposes it.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { boot } = require("./harness.cjs");

// Read every UI source (the framework + panels), as the browser does via the
// manifest, and derive the panel module list (lib/*_panel.rb basenames).
function readUiSources() {
  const libDir = path.join(__dirname, "../ruby/lib");
  const files = {};
  const panels = [];
  for (const f of fs.readdirSync(libDir).sort()) {
    if (!f.endsWith(".rb")) continue;
    files["lib/" + f] = fs.readFileSync(path.join(libDir, f), "utf8");
    // Feature panels are *_panel.rb; ui_panel.rb is the framework base.
    if (f.endsWith("_panel.rb") && !f.startsWith("ui_")) panels.push(f.slice(0, -3));
  }
  return { files, panels };
}

// The Pads tab is a tab div whose text is "Pads"; find it among the cursor
// tabs (the dock buttons are <button>, not div, so they are not matched).
function findTab(label) {
  return [...globalThis.document.querySelectorAll("#app div")].find(
    (d) => d.textContent === label && (d.getAttribute("class") || "").includes("cursor-pointer")
  );
}

describe("funicular Panel UI from /_web", () => {
  let h;
  const padCalls = [];
  before(async () => {
    h = await boot();
    const { installUI, startUI } = await import("../js/engine/ui.js");
    // JS.global resolves to `window` (picoruby-wasm js.c), so expose the bridge
    // there; in the browser window === globalThis, so the Engine sets it there.
    let pending = ["boot: alpha", "boot: bravo"];
    globalThis.window.__harucomBridge = {
      takePrints: () => { const p = pending; pending = []; return p; },
      keyInfo: () => "last key: code=KeyZ",
      frame: () => 0,
      audio: () => ({ underruns: 0, level: 0 }),
      setPad: (pad, dir, down) => { padCalls.push([pad, dir, down]); },
      startAudio: () => {},
    };
    const { files, panels } = readUiSources();
    installUI(h.Module, files);
    startUI(h.Module, { panels });
    h.drive(8000); // run the boot task: require + register + mount + poll/drain
  });

  it("writes the UI under /_web (visible to the OS by design)", () => {
    const out = h.evalInIRB('p File.exist?("/_web/lib/shell.rb")', "=> ");
    assert.match(out, /=> true/, out);
  });

  it("builds a tab per self-registered panel, ordered", () => {
    const html = globalThis.document.getElementById("app").innerHTML;
    assert.match(html, /Console/, html);
    assert.match(html, /Keys/, html);
    assert.match(html, /Pads/, html);
    assert.match(html, /Status/, html);
  });

  it("shows the Console panel (lowest order) by default with drained stdout", () => {
    const html = globalThis.document.getElementById("app").innerHTML;
    assert.match(html, /boot: alpha/, html);
    assert.match(html, /boot: bravo/, html);
  });

  it("switches to the Keys tab and renders the keyboard debug string", () => {
    const tab = findTab("Keys");
    assert.ok(tab, "Keys tab present");
    tab.dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800); // the onclick callback is enqueued on the VM scheduler
    const keys = globalThis.document.querySelector("#app #keys");
    assert.ok(keys, "Keys panel mounted");
    assert.match(keys.textContent, /code=KeyZ/, keys.textContent);
  });

  it("switches tabs and drives bridge.setPad from a pad button press", () => {
    const tab = findTab("Pads");
    assert.ok(tab, "Pads tab present");
    tab.dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800); // the onclick callback is enqueued on the VM scheduler

    const pads = globalThis.document.querySelectorAll("#app #pads > div");
    assert.equal(pads.length, 2, "two D-pads");
    const btns = globalThis.document.querySelectorAll("#app #pads button");
    assert.equal(btns.length, 8, "four buttons per pad");

    btns[0].dispatchEvent(new globalThis.window.Event("pointerdown")); // pad 0, dir UP=1
    h.drive(400);
    assert.deepEqual(padCalls[0], [0, 1, true], JSON.stringify(padCalls));
  });

  it("docks to the right, keeping the canvas and the active panel", () => {
    // Switching dock re-renders App; Screen and Panels are preserved (preserve:
    // true), so the canvas keeps its 2D context and the active tab (Pads, from
    // the previous test) survives.
    const dockRight = [...globalThis.document.querySelectorAll("#app button")]
      .find((b) => b.textContent === "⊣");
    assert.ok(dockRight, "right-dock button present");
    dockRight.dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);

    const outer = globalThis.document.querySelector("#app > div");
    assert.match(outer.getAttribute("class"), /flex-row/, outer.getAttribute("class"));
    assert.ok(globalThis.document.querySelector("#app #screen-host canvas"), "canvas preserved");
    assert.ok(globalThis.document.querySelector("#app #pads"), "active Pads panel preserved");
  });
});
