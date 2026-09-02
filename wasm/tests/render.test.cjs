// DVI render gate: the banner is drawn on the DVI text surface and committed, so
// after boot the framebuffer (the same pixels the browser canvas blits) holds
// non-background pixels.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("DVI render", () => {
  let width, height, nonbg, colors, frames;
  before(async () => {
    const { Module } = await boot();
    width = Module._harucom_dvi_width();
    height = Module._harucom_dvi_height();
    const fb = Module._harucom_dvi_framebuffer();
    const px = Module.HEAPU8.subarray(fb, fb + width * height);
    const BG = 0x00; // palette[0], default background (see default_palette[])
    nonbg = 0;
    colors = new Set();
    for (let i = 0; i < px.length; i++) {
      if (px[i] !== BG) nonbg++;
      colors.add(px[i]);
    }
    frames = Module._harucom_dvi_frame_count();
  });

  it("is 640x480", () => {
    assert.equal(width, 640);
    assert.equal(height, 480);
  });
  it("has non-background pixels", (t) => {
    t.diagnostic(`non-bg=${nonbg}, distinct colors=${colors.size}`);
    assert.ok(nonbg > 500, `expected >500 non-bg pixels, got ${nonbg}`);
  });
  it("committed at least one frame", () => {
    assert.ok(frames > 0);
  });
});
