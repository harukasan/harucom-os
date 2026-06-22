// Boot gate: /system.rb must run the full userland (deploy rootfs, require the
// console / IME / line editor / keyboard / IRB libraries) and reach the IRB
// banner. The Console mirrors its DVI output to STDOUT (fd 1), so the banner is
// captured here even though it is really painted on the text surface. Reaching
// the banner means every require resolved and IRB started; a failed require or a
// raised exception would stop before it.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("Ruby boot", () => {
  let h;
  before(async () => { h = await boot(); });

  it("deploys the rootfs to MEMFS", (t) => {
    t.diagnostic(`drove ${h.bootSteps} scheduler steps`);
    assert.match(h.printed(), /rootfs: deployed \d+ files/);
  });
  it("reaches the IRB banner (every require resolved)", () => {
    assert.ok(h.printed().includes("Powered by PicoRuby"));
  });
  it("prints the banner author line", () => {
    assert.ok(h.printed().includes("Shunsuke Michii"));
  });
});
