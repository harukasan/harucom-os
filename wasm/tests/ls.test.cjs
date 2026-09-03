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

let h, out, longOut;

before(async () => {
  h = await boot();
  // runApp, not evalInIRB: the shell prints no "=>" once an app is done, so
  // waiting on one only spends the step budget. This waits for the output to go
  // quiet instead.
  out = h.runApp("ls");
  longOut = h.runApp("ls -l");
});

describe("ls", () => {
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
  // The header has to name the columns the rows actually print. It once carried
  // LittleFS's own label, which starts at the size and so was one column short.
  it("heads the listing with the columns it prints", () => {
    const plain = longOut.replace(/\u001b\[\d+m/g, "");
    const header = plain.split("\n")[0];
    assert.match(header, /^T\s+size\s+datetime\s+name$/, JSON.stringify(header));
    const row = plain.split("\n").find((l) => l.includes("system.rb"));
    assert.ok(row, "the file is listed: " + JSON.stringify(longOut));
    assert.equal(header.indexOf("size") + 4, /^[d-] +\d+/.exec(row)[0].length,
                 "size label ends where the size does: " + JSON.stringify([header, row]));
    assert.equal(header.indexOf("datetime"), /^[d-] +\d+ /.exec(row)[0].length,
                 "datetime label starts where the stamp does: " + JSON.stringify([header, row]));
  });

  it("marks a directory with d and a file with -", () => {
    assert.ok(/^d\s+\d+\s+.*app/m.test(longOut.replace(/\u001b\[\d+m/g, "")),
              "a directory row: " + JSON.stringify(longOut));
    assert.ok(/^-\s+\d+\s+.*system\.rb/m.test(longOut), "a file row: " + JSON.stringify(longOut));
  });

  it("reports a size and a time for each entry", () => {
    const plain = longOut.replace(/\u001b\[\d+m/g, "");
    const row = plain.split("\n").find((l) => l.includes("system.rb"));
    assert.ok(row, "the file is listed: " + JSON.stringify(longOut));
    assert.ok(/\d{4}-\d{2}-\d{2}/.test(row), "with a timestamp: " + row);
    assert.ok(/\s\d+\s/.test(row), "and a size: " + row);
  });

  it("works on a single file too, which took a separate path", () => {
    const single = h.runApp("ls -l /system.rb").replace(/\u001b\[\d+m/g, "");
    assert.ok(/^-\s+\d+\s/m.test(single), JSON.stringify(single));
    // The same header as a directory listing: one -l should not print two
    // different formats depending on what it was pointed at.
    assert.ok(single.split("\n").some((l) => /^T\s+size\s+datetime\s+name$/.test(l)),
              "headed like a directory listing: " + JSON.stringify(single));
  });
});
