// Graphics gate: from IRB, switch to graphics mode and fill a red (RGB332 0xE0)
// rectangle, then assert it appears in the displayed framebuffer. Exercises
// dvi_set_mode + the DVI::Graphics primitives + the wasm dvi_graphics_commit
// present path (graphics_buf -> framebuffer).
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("graphics mode", () => {
  const W = 640;
  const center = 125 * W + 125; // center of a 50x50 rect at (100,100)
  let centerPixel, red;
  before(async () => {
    const { Module, typeString, hidType, drive, ENTER } = await boot();
    const fb = Module._harucom_dvi_framebuffer();
    typeString("DVI.set_mode(DVI::GRAPHICS_MODE)");
    hidType(ENTER);
    drive(2000);
    typeString("DVI::Graphics.fill_rect(100,100,50,50,224);DVI::Graphics.commit");
    hidType(ENTER);
    for (let i = 0; i < 40000; i++) {
      Module._mrb_tick_wasm();
      Module._mrb_run_step();
      if (i % 64 === 0 && Module.HEAPU8[fb + center] === 0xE0) break;
    }
    const px = Module.HEAPU8.subarray(fb, fb + W * 480);
    centerPixel = px[center];
    red = 0;
    for (let i = 0; i < px.length; i++) if (px[i] === 0xE0) red++;
  });

  it("renders the rect (center pixel is red)", (t) => {
    t.diagnostic(`red=${red}, center=0x${centerPixel.toString(16)}`);
    assert.equal(centerPixel, 0xE0);
  });
  it("fills ~50x50 red pixels", () => {
    assert.ok(red >= 2000, `expected >=2000 red pixels, got ${red}`);
  });
});
