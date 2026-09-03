// ls on the browser build.
//
// The columns and the header are pinned on the host (tests/ls_format_test.rb),
// which takes the same no-File::Stat branch the browser does. What only the
// browser can answer is whether its filesystem backs that branch: File.directory?
// for the colour, and an open handle for the size and the time. Getting either
// wrong is quiet, because the listing still prints.
//
// One command, and nothing typed after it. The shell prints nothing when an app
// exits and draws the prompt to the screen rather than to stdout, so there is no
// marker in the output that says it is taking input again. Waiting on the rows
// themselves is exact, and a line typed later could be dropped by the drain the
// shell runs while it tears the app down.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

const BLUE = "\u001b[34m"; // what ls emits for a directory

let out, plain;

before(async () => {
  const h = await boot();
  const start = h.output.length;
  h.typeString("ls -l /");
  h.hidType(h.ENTER);
  // Dir fixes no order, so wait for each row rather than assuming which is last.
  for (const row of ["system.rb", "app"]) {
    const steps = h.driveUntil(row, 40000, start);
    assert.ok(steps < 40000, `ls -l listed ${row}: ` + JSON.stringify(h.output.slice(start)));
  }
  out = h.output.slice(start).join("\n");
  plain = out.replace(/\u001b\[\d+m/g, "");
});

describe("ls -l", () => {
  it("colours a directory and leaves a file plain", () => {
    assert.ok(out.includes(BLUE + "app"), JSON.stringify(out));
    assert.ok(!out.includes(BLUE + "system.rb"), JSON.stringify(out));
  });

  it("marks a directory with d and a file with -", () => {
    assert.match(plain, /^d\s+\d+\s.*\bapp$/m);
    assert.match(plain, /^-\s+\d+\s.*\bsystem\.rb$/m);
  });

  it("reads a size and a time off the browser filesystem", () => {
    const row = plain.split("\n").find((line) => line.endsWith("system.rb"));
    assert.match(row, /^-\s+[1-9]\d*\s/, "a size read from the file: " + row);
    assert.match(row, /\d{4}-\d{2}-\d{2}/, "a time read from the file: " + row);
  });
});
