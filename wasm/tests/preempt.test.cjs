// Scheduler preemption gate: the opcode-budget preemption hook must split a long
// busy Ruby loop across many mrb_run_step calls. The driver only ticks the clock
// between steps, so without the hook the whole loop would run inside a single
// mrb_run_step (and in the browser would freeze the tab); with it, the loop
// yields every budget of opcodes, so it takes many steps to finish.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("scheduler preemption (opcode-budget hook)", () => {
  let steps, done;
  before(async () => {
    const h = await boot();
    const start = h.output.length;
    h.typeString("i=0;while i<1000000;i=i+1;end;puts i");
    h.hidType(h.ENTER);
    steps = 0;
    done = false;
    for (let i = 0; i < 100000; i++) {
      h.Module._mrb_tick_wasm();
      h.Module._mrb_run_step();
      steps++;
      if (h.output.slice(start).join("").includes("1000000")) { done = true; break; }
    }
  });

  it("completes the loop", () => assert.ok(done));
  it("spread the loop across many steps (hook active)", (t) => {
    t.diagnostic(`steps=${steps}`);
    assert.ok(steps > 50, `expected >50 steps, got ${steps}`);
  });
});
