// A stub engine for the component tests: every command recorded, no events
// unless a test emits one. Shared so a new method on Engine is added in one
// place rather than in every test file.
import { vi, type Mock } from "vitest";
import type { Engine, EngineEvents, ConsoleLog } from "./engine";

// The commands are vitest mocks, so a test can read what the component asked
// the engine to do.
type Mocked<T> = T extends (...args: infer A) => infer R ? Mock<(...args: A) => R> : T;

export interface StubEngine extends Engine {
  start: Mocked<Engine["start"]>;
  setPad: Mocked<Engine["setPad"]>;
  releasePads: Mocked<Engine["releasePads"]>;
  armAudio: Mocked<Engine["armAudio"]>;
  keyDown: Mocked<Engine["keyDown"]>;
  keyUp: Mocked<Engine["keyUp"]>;
  setKeyModifier: Mocked<Engine["setKeyModifier"]>;
  /** Deliver an event to whatever the component subscribed. */
  emit<E extends keyof EngineEvents>(event: E, value: EngineEvents[E]): void;
}

export function stubEngine(log: ConsoleLog | null = null): StubEngine {
  const listeners = new Map<string, ((value: never) => void)[]>();
  return {
    start: vi.fn(),
    setPad: vi.fn(),
    releasePads: vi.fn(),
    armAudio: vi.fn(),
    keyDown: vi.fn(),
    keyUp: vi.fn(),
    setKeyModifier: vi.fn(),
    log,
    on(event, callback) {
      const list = listeners.get(event) ?? [];
      list.push(callback as (value: never) => void);
      listeners.set(event, list);
      return () => {
        const i = list.indexOf(callback as (value: never) => void);
        if (i >= 0) list.splice(i, 1);
      };
    },
    emit(event, value) {
      for (const callback of (listeners.get(event) ?? []).slice()) {
        (callback as (v: typeof value) => void)(value);
      }
    },
  };
}
