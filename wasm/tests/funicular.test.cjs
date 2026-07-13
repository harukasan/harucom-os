// Phase 2 smoke: funicular is linked into the harucom OS VM, and its VDOM
// pipeline (Component -> render -> Renderer -> JS bridge) drives a real DOM. This
// runs headlessly under jsdom, so funicular UI is testable without a browser, not
// only by visual inspection.
//
// The Ruby is typed through the keyboard pipeline, which only maps a subset of
// ASCII and corrupts very long lines, so each line is kept short, the render
// block uses do/end (no { } or |), and the mount is split across submissions.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("funicular", () => {
  let h;
  before(async () => { h = await boot(); });

  it("is loaded in the OS VM", () => {
    const out = h.evalInIRB("Funicular::VERSION", "0.1.0", 20000);
    assert.ok(out.includes('"0.1.0"'), out);
  });

  it("mounts a Component into the DOM through the JS bridge (jsdom)", () => {
    // Define a minimal component that renders <div id="m">FUNOK</div>.
    h.typeString('class S < Funicular::Component; def render; div(id:"m") do "FUNOK" end; end; end');
    h.hidType(h.ENTER);
    h.drive(1500);
    // Mount it into the #app container (provided by the harness DOM).
    h.typeString('Funicular.start(S, container:"app")');
    h.hidType(h.ENTER);
    h.drive(2500);
    // Read the mounted text back through the bridge. FUNOK is absent from this
    // line, so the marker only matches the result, not the typed echo.
    const out = h.evalInIRB('JS.document.getElementById("m")[:textContent].to_s', "FUNOK", 20000);
    assert.ok(out.includes("FUNOK"), out);
  });
});
