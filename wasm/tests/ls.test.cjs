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

// The long format asks the same question a different way. It used to go through
// File::Stat for the size and the time and through mode_str for a permission
// column, and mode_str has no implementation on any platform, so -l raised
// wherever it was run.
describe("ls -l", () => {
  let h, out;
  before(async () => {
    h = await boot();
    out = h.evalInIRB("ls -l", "=>");
  });

  it("marks a directory with d and a file with -", () => {
    assert.ok(/^d\s+\d+\s+.*app/m.test(out.replace(/\u001b\[\d+m/g, "")),
              "a directory row: " + JSON.stringify(out));
    assert.ok(/^-\s+\d+\s+.*system\.rb/m.test(out), "a file row: " + JSON.stringify(out));
  });

  it("reports a size and a time for each entry", () => {
    const plain = out.replace(/\u001b\[\d+m/g, "");
    const row = plain.split("\n").find((l) => l.includes("system.rb"));
    assert.ok(row, "the file is listed: " + JSON.stringify(out));
    assert.ok(/\d{4}-\d{2}-\d{2}/.test(row), "with a timestamp: " + row);
    assert.ok(/\s\d+\s/.test(row), "and a size: " + row);
  });

  it("works on a single file too, which took a separate path", () => {
    const single = h.evalInIRB("ls -l /system.rb", "system.rb");
    assert.ok(/^-\s+\d+\s/m.test(single), JSON.stringify(single));
  });
});
