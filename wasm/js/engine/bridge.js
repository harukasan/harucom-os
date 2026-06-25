// Engine <-> Shell bridge: a plain JS object the funicular UI (Ruby) reads and
// commands. It is exposed as window.__harucomBridge so JS.global (= window in
// picoruby-wasm) can reach it.
//
// Engine -> Shell is poll-based: the engine's print/keys events buffer here and
// the Shell drains them each scheduler pass (a synchronous JS -> Ruby callback
// would re-enter the VM mid-mrb_run_step). Shell -> Engine commands call straight
// through (they only touch C state, so no re-entrancy).

export function createBridge(engine) {
  let prints = [];
  let keyInfo = "";

  engine.on("print", (line) => { prints.push(line); });
  engine.on("keys", (text) => { keyInfo = text; });

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
    // Commands (Shell -> Engine).
    setPad(pad, dir, down) {
      engine.setPad(pad, dir, down);
    },
    startAudio() {
      engine.startAudio();
    },
  };
}
