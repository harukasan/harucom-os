// ls colouring gate.
//
// /app/ls.rb marks directories with an ANSI colour. It decides with
// File.directory?, which every platform has, rather than File::Stat, which comes
// from the filesystem gem and does not exist on a build without a VFS. Getting
// that wrong is quiet: the listing still prints, only uncoloured, because the
// surrounding code falls back to the bare name.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

const BLUE = "\u001b[34m"; // what ls emits for a directory

describe("ls", () => {
  let out;
  before(async () => {
    const h = await boot();
    // Wait for the IRB prompt rather than the last listed name, so the app has
    // finished being torn down before anything else types.
    out = h.evalInIRB("ls", "=>");
  });

  it("colours a directory", () => {
    assert.ok(out.includes(BLUE + "app"), JSON.stringify(out));
  });

  it("leaves a file plain", () => {
    assert.ok(out.includes("system.rb"), "the file is listed: " + JSON.stringify(out));
    assert.ok(!out.includes(BLUE + "system.rb"), "and not coloured: " + JSON.stringify(out));
  });
});
