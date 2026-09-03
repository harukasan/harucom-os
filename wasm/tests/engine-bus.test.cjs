// The two pure pieces behind the shell's panels: the event bus the engine
// dispatches through, and the console buffer the console panel reads.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");

let createEventBus, createConsoleLog;
before(async () => {
  ({ createEventBus } = await import("../js/engine/events.js"));
  ({ createConsoleLog } = await import("../js/engine/console-log.js"));
});

describe("event bus", () => {
  it("delivers to every subscriber of an event", () => {
    const bus = createEventBus();
    const seen = [];
    bus.on("frame", (n) => seen.push("a" + n));
    bus.on("frame", (n) => seen.push("b" + n));
    bus.on("audio", () => seen.push("audio"));
    bus.emit("frame", 7);
    assert.deepEqual(seen, ["a7", "b7"]);
  });

  it("stops delivering after unsubscribe", () => {
    const bus = createEventBus();
    const seen = [];
    const off = bus.on("frame", (n) => seen.push(n));
    bus.emit("frame", 1);
    off();
    bus.emit("frame", 2);
    assert.deepEqual(seen, [1]);
  });

  // A React effect cleaning up during a dispatch unsubscribes mid-emit. Without
  // the copy, splicing the live array would step the loop past the next handler.
  it("still reaches later subscribers when one unsubscribes mid-dispatch", () => {
    const bus = createEventBus();
    const seen = [];
    const off = bus.on("frame", () => { seen.push("first"); off(); });
    bus.on("frame", () => seen.push("second"));
    bus.emit("frame", 1);
    assert.deepEqual(seen, ["first", "second"]);
  });
});

describe("console log", () => {
  it("keeps the history for a panel that mounts later", () => {
    const log = createConsoleLog();
    log.write("boot");
    log.write("ready");
    assert.deepEqual(log.lines(), ["boot", "ready"]);
  });

  it("drops the oldest lines past the cap", () => {
    const log = createConsoleLog({ limit: 3 });
    for (const line of ["a", "b", "c", "d"]) log.write(line);
    assert.deepEqual(log.lines(), ["b", "c", "d"]);
  });

  // React re-renders on identity, so handing back the same mutated array would
  // leave the console frozen at whatever it first showed.
  it("hands out a new array each write", () => {
    const log = createConsoleLog();
    const seen = [];
    log.subscribe((lines) => seen.push(lines));
    log.write("one");
    log.write("two");
    assert.equal(seen.length, 2);
    assert.notEqual(seen[0], seen[1]);
    assert.deepEqual(seen[0], ["one"]);
  });

  it("stops notifying after unsubscribe", () => {
    const log = createConsoleLog();
    let count = 0;
    const off = log.subscribe(() => count++);
    log.write("one");
    off();
    log.write("two");
    assert.equal(count, 1);
  });
});
