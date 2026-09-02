// Typed view of the JS engine.
//
// The engine modules stay plain JS because the node smoke tests import them
// directly (wasm/tests/*.test.cjs), which they could not do through a TypeScript
// source. This file is the one place that knows the shape, so the components
// consume a real interface rather than any.
import { createEngine as create } from "../../js/engine/index.js";

export interface Engine {
  /** Init the VM, prune the emscripten-only dirs and start the run loop. */
  start(): void;
  setPad(pad: number, dir: number, down: boolean): void;
  releasePads(): void;
  /** Arm Web Audio from a user gesture. */
  armAudio(): void;
}

/** The emscripten Module. Only the engine touches its internals. */
export type HarucomModule = object;

export function createEngine(module: HarucomModule, options: { canvas: HTMLCanvasElement }): Engine {
  return create(module, options) as Engine;
}
