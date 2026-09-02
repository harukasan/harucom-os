// IME dictionary gate: look up the SKK reading にほん (entered as \u escapes so
// the keystrokes stay ASCII). The embedded /dict.bin, loaded by dict_wasm_init
// via the ports/posix dict port, must resolve it to include 日本.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("IME dictionary", () => {
  let h;
  before(async () => { h = await boot(); });

  it("resolves an SKK dictionary lookup (にほん -> 日本)", () => {
    const out = h.evalInIRB('puts InputMethod.skk_lookup("\\u306b\\u307b\\u3093")', "日本");
    assert.ok(out.includes("日本"), out);
  });
});
