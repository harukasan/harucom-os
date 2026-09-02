// Consumer health reporting.
//
// Only the AudioWorklet knows how the browser's audio consumer is doing, and it
// runs on its own thread, so JavaScript forwards its buffer level through
// harucom_audio_report and PWMAudio.stats reports it. That path needs no Web
// Audio to test: the export and PWMAudio.stats are both reachable here.
//
// The case worth pinning is the running minimum. The worklet unavoidably reports
// an empty buffer between starting and the first pump landing, so without a
// reset in init that transient latches and every later reading claims a dry
// buffer, which is how this started out.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("audio health reporting", () => {
  let h;
  before(async () => { h = await boot(); });

  const stats = () => h.evalInIRB("p PWMAudio.stats", "[");
  const report = (level) => h.Module._harucom_audio_report(level);

  it("reports a full buffer before anything has been measured", () => {
    const out = stats();
    // Not 0: the contract spells that as the consumer having run dry.
    assert.ok(!out.includes("[0,"), "an unmeasured buffer is not a dry one: " + out);
  });

  it("reports the lowest level seen", () => {
    report(2000);
    report(900);
    report(1500);
    assert.ok(stats().includes("[900,"), stats());
  });

  it("starts a fresh window on init, so a priming dip does not latch", () => {
    report(0); // what the worklet reports before the first pump lands
    assert.ok(stats().includes("[0,"), "the dip is visible: " + stats());
    h.evalInIRB("PWMAudio.deinit; PWMAudio.init(24,25)", "=>");
    assert.ok(!stats().includes("[0,"),
              "init must clear it, or every later reading claims a dry buffer: " + stats());
  });

  it("leaves the pump gap alone, which is documented in microseconds", () => {
    report(500);
    assert.ok(stats().includes(", 0, "), "no gap is reported here: " + stats());
  });
});
