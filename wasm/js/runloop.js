// Drive the mruby task scheduler from requestAnimationFrame.
//
// Clock: advance mrb_tick_wasm to match real elapsed time at MRB_TICK_UNIT (4ms)
// granularity, about 4 ticks per 60fps frame. Sleeping tasks only wake on ticks,
// so this keeps sleep_ms / DVI.wait_vsync real-time-accurate and lets the line
// editor wake every frame (ticking only once per frame made sleep_ms 16 take ~4
// frames, so input and redraw lagged at ~15fps). The catch-up is capped so
// returning from a background tab, where rAF was paused, does not replay a long
// backlog of ticks at once.
//
// Steps: run a batch of task slices so the always-ready keyboard task polls every
// frame and any woken task runs to its next yield. More steps beyond draining the
// ready queue does not help smoothness (the work tasks are gated by the clock,
// not the step count) and only spins the Task.pass loops. applyReleases() then
// drops keys released this frame, after the batch polled them, so a same-frame
// key down+up is still seen once.

const MRB_TICK_UNIT = 4;     // ms per tick; must match build_config/harucom-wasm.rb
const MAX_CATCHUP_TICKS = 8; // cap clock catch-up after a stall / background tab
const STEPS_PER_FRAME = 16;

// Start the rAF loop. blit/applyReleases/pump are the per-frame hooks from the
// display, keyboard, and audio modules.
export function startRunLoop(Module, { blit, applyReleases, pump }) {
  let lastFrame = -1;
  let lastTick = performance.now();

  function step() {
    const now = performance.now();
    let ticks = 0;
    while (now - lastTick >= MRB_TICK_UNIT && ticks < MAX_CATCHUP_TICKS) {
      Module._mrb_tick_wasm();
      lastTick += MRB_TICK_UNIT;
      ticks++;
    }
    if (now - lastTick >= MRB_TICK_UNIT) lastTick = now; // fell too far behind; resync
    for (let s = 0; s < STEPS_PER_FRAME; s++) Module._mrb_run_step();
    applyReleases();
    pump(); // refill the audio buffer from the synth ring
    const frame = Module._harucom_dvi_frame_count();
    if (frame !== lastFrame) {
      lastFrame = frame;
      blit();
    }
    requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}
