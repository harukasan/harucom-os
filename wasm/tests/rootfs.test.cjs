// Filesystem-root gate: the wasm MEMFS root should match the board's LittleFS
// root. boot() (harness.cjs) runs the same pruneRuntimeDirs() the browser entry
// does, so the emscripten-only dirs (/home, /tmp, /proc) are gone while the
// rootfs and /dev (kept for the posix RNG's /dev/urandom) remain.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("filesystem root matches the board", () => {
  let h;
  before(async () => { h = await boot(); });

  it("removes the emscripten-only dirs (/home, /tmp, /proc)", () => {
    const out = h.evalInIRB(
      'p [File.exist?("/home"),File.exist?("/tmp"),File.exist?("/proc")]', "=> [");
    assert.match(out, /\[false, false, false\]/, out);
  });

  it("keeps the rootfs and /dev", () => {
    const out = h.evalInIRB(
      'p [File.exist?("/system.rb"),Dir.exist?("/lib"),File.exist?("/dev")]', "=> [");
    assert.match(out, /\[true, true, true\]/, out);
  });
});
