// Unit tests for the AudioWorklet processor. No Web Audio and no wasm: the
// class only needs a base with a port, so stubbing the two globals the module
// touches at load time is enough to drive process() directly.
//
// The behaviour worth pinning is that it stays quiet until it has been fed.
// process() starts as soon as the node connects, a frame or more before the
// pump can post anything, and a level of zero there is not the consumer running
// dry. Reporting it puts a permanent "ran dry" into the running minimum behind
// PWMAudio.stats, which is exactly how that reading first went wrong.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

const QUANTUM = 128;

let Processor;
before(async () => {
  globalThis.AudioWorkletProcessor = class {
    constructor() {
      this.port = { onmessage: null, sent: [], postMessage(m) { this.sent.push(m); } };
    }
  };
  globalThis.registerProcessor = (_name, klass) => { Processor = klass; };
  await import("../js/engine/audio-worklet.js");
});

// Run `quanta` render quantums and return the processor.
function run(processor, quanta) {
  const outputs = [[new Float32Array(QUANTUM), new Float32Array(QUANTUM)]];
  for (let i = 0; i < quanta; i++) processor.process([], outputs);
  return processor;
}

function feed(processor, frames) {
  processor.port.onmessage({
    data: { l: new Float32Array(frames), r: new Float32Array(frames) },
  });
}

describe("audio worklet", () => {
  it("says nothing until it has been fed", () => {
    const p = run(new Processor(), 100);
    assert.equal(p.port.sent.length, 0,
      "a level of zero here is not an underrun, it is silence before the first pump");
  });

  it("reports once it has frames", () => {
    const p = new Processor();
    feed(p, 4096);
    run(p, 12);
    assert.ok(p.port.sent.length > 0, "reports resume once there is something to report");
    assert.ok(p.port.sent[0].lvl > 0, JSON.stringify(p.port.sent[0]));
  });

  it("throttles to about one report per frame, not one per quantum", () => {
    const p = new Processor();
    feed(p, 65536);
    run(p, 60);
    // 6 quanta per report, so 60 quanta is 10 reports rather than 60.
    assert.ok(p.port.sent.length <= 12,
      "a report per quantum would flood the thread this design keeps free: " + p.port.sent.length);
  });

  it("drops rather than writing over frames it has not played", () => {
    const p = new Processor();
    feed(p, 40000); // more than the 32768-frame ring
    run(p, 12);
    const last = p.port.sent[p.port.sent.length - 1];
    assert.ok(last.dropped > 0, "the overflow is counted: " + JSON.stringify(last));
    assert.ok(last.lvl <= 32768, "and the ring never reports more than it holds");
  });
});
