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

// A dock-mode button is a <button> whose text is the glyph (Float ⧉ / bottom ⊥ / right ⊣).
function dockBtn(glyph) {
  return [...globalThis.document.querySelectorAll("#app button")].find((b) => b.textContent === glyph);
}

// Dispatch a pointer event carrying client coordinates (jsdom's Event lacks them).
function pointer(type, x, y) {
  const e = new globalThis.window.Event(type, { bubbles: true });
  Object.defineProperty(e, "clientX", { value: x });
  Object.defineProperty(e, "clientY", { value: y });
  e.pointerId = 1;
  e.preventDefault = () => {};
  return e;
}

describe("funicular Panel UI from /_web", () => {
  let h;
  const padCalls = [];
  const keyCalls = [];
  const modCalls = [];
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
      keyDown: (usage) => { keyCalls.push(["down", usage]); },
      keyUp: (usage) => { keyCalls.push(["up", usage]); },
      setKeyModifier: (mask) => { modCalls.push(mask); },
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
    assert.match(html, /Keyboard/, html);
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

  it("types keys and latches Shift from the Keyboard panel", () => {
    findTab("Keyboard").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    const btns = () => [...globalThis.document.querySelectorAll("#app #keyboard button")];

    const a = btns().find((b) => b.textContent === "A"); // HID usage 0x04
    assert.ok(a, "A key present");
    a.dispatchEvent(new globalThis.window.Event("pointerdown"));
    h.drive(400);
    assert.deepEqual(keyCalls.at(-1), ["down", 0x04], JSON.stringify(keyCalls.slice(-2)));
    a.dispatchEvent(new globalThis.window.Event("pointerup"));
    h.drive(400);
    assert.deepEqual(keyCalls.at(-1), ["up", 0x04]);

    // Shift latches the LeftShift overlay and highlights the key.
    btns().find((b) => b.textContent === "Shift").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    assert.equal(modCalls.at(-1), 0x02, JSON.stringify(modCalls));
    const shift = btns().find((b) => b.textContent === "Shift");
    assert.match(shift.getAttribute("class"), /bg-pad-on/, shift.getAttribute("class"));
    // Tapping Shift again unlatches it.
    shift.dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    assert.equal(modCalls.at(-1), 0x00);

    // Function keys and Del send their HID usages; Alt latches the LeftAlt bit.
    btns().find((b) => b.textContent === "F5").dispatchEvent(new globalThis.window.Event("pointerdown"));
    h.drive(400);
    assert.deepEqual(keyCalls.at(-1), ["down", 0x3e], JSON.stringify(keyCalls.slice(-2)));
    btns().find((b) => b.textContent === "Del").dispatchEvent(new globalThis.window.Event("pointerdown"));
    h.drive(400);
    assert.deepEqual(keyCalls.at(-1), ["down", 0x4c]);
    btns().find((b) => b.textContent === "Alt").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    assert.equal(modCalls.at(-1), 0x04, JSON.stringify(modCalls));
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

  it("resizes the bottom dock with the edge splitter", () => {
    // The undocked default box resizes via CSS (no JS, untestable here); the
    // bottom/right docks resize via the splitter, which is what this checks.
    dockBtn("⊥").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    const dock = globalThis.document.getElementById("dock");
    const grip = globalThis.document.querySelector("#app .cursor-row-resize");
    assert.ok(grip, "bottom splitter present");
    grip.setPointerCapture = () => {};
    grip.releasePointerCapture = () => {};

    const before = dock.getAttribute("style"); // height:256px
    grip.dispatchEvent(pointer("pointerdown", 0, 400));
    h.drive(200);
    grip.dispatchEvent(pointer("pointermove", 0, 360)); // drag up 40px -> +40 height
    h.drive(200);
    grip.dispatchEvent(pointer("pointerup", 0, 360));
    h.drive(300);

    assert.notEqual(dock.getAttribute("style"), before, "dock resized");
    assert.match(dock.getAttribute("style"), /height:\d+px/, dock.getAttribute("style"));
  });

  it("switches docks (bottom then right), keeping the canvas and active panel", () => {
    // Undocked -> bottom remounts Panels, so re-select Pads; bottom -> right is an
    // edge-to-edge switch that preserves Panels (active tab survives), and the
    // canvas (Screen) is preserved across every switch.
    dockBtn("⊥").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    findTab("Pads").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    dockBtn("⊣").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);

    const outer = globalThis.document.querySelector("#app > div");
    assert.match(outer.getAttribute("class"), /flex-row/, outer.getAttribute("class"));
    assert.ok(globalThis.document.querySelector("#app #screen-host canvas"), "canvas preserved");
    assert.ok(globalThis.document.querySelector("#app #pads"), "active Pads panel preserved across bottom->right");
  });

  it("clears the undocked box's CSS-resize size when docking (no giant splitter)", () => {
    // Back to undocked, simulate a CSS resize leaving an inline size, then dock:
    // the splitter reuses that DOM node and must not inherit width/height.
    dockBtn("▢").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    const box = globalThis.document.querySelector("#app .undock-box");
    assert.ok(box, "undocked box present");
    box.setAttribute("style", "width:700px;height:430px");

    dockBtn("⊥").dispatchEvent(new globalThis.window.Event("click"));
    h.drive(800);
    const grip = globalThis.document.querySelector("#app .cursor-row-resize");
    assert.ok(grip, "splitter present");
    const style = grip.getAttribute("style") || "";
    assert.doesNotMatch(style, /width|height/, `splitter inherited the box size: "${style}"`);
  });
});
