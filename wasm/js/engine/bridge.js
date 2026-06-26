// Engine <-> UI bridge: a plain JS object the funicular UI (Ruby) reads and
// commands. It is exposed as window.__harucomBridge so JS.global (= window in
// picoruby-wasm) can reach it.
//
// Engine -> UI is poll-based: the engine's events buffer here and the Engine
// Ruby facade drains them each scheduler pass (a synchronous JS -> Ruby callback
// would re-enter the VM mid-mrb_run_step). UI -> Engine commands call straight
// through (they only touch C state, so no re-entrancy).

export function createBridge(engine) {
  let prints = [];
  let keyInfo = "";
  let frame = 0;
  let underruns = 0;
  let level = 0;

  engine.on("print", (line) => { prints.push(line); });
  engine.on("keys", (text) => { keyInfo = text; });
  engine.on("frame", (f) => { frame = f; });
  engine.on("audio", (diag) => { underruns = diag.underruns; level = diag.level; });

  return {
    // Return and clear the stdout/stderr lines accumulated since the last call.
    takePrints() {
      const out = prints;
      prints = [];
      return out;
    },
    // The latest keyboard debug string.
    keyInfo() {
      return keyInfo;
    },
    // The latest DVI frame count.
    frame() {
      return frame;
    },
    // The latest audio diagnostics ({ underruns, level }).
    audio() {
      return { underruns, level };
    },
    // Commands (UI -> Engine).
    setPad(pad, dir, down) {
      engine.setPad(pad, dir, down);
    },
    startAudio() {
      engine.startAudio();
    },
  };
}
