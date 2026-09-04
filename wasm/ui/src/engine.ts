// Typed view of the JS engine.
//
// The engine modules stay plain JS because the node smoke tests import them
// directly (wasm/tests/*.test.cjs), which they could not do through a TypeScript
// source. This file is the one place that knows the shape, so the components
// consume a real interface rather than any.
import { createEngine as create } from "../../js/engine/index.js";
import { createConsoleLog as createLog } from "../../js/engine/console-log.js";

/** A one-second sample of how the audio worklet is coping. */
export interface AudioDiagnostics {
  level: number;
  underruns: number;
  dropped: number;
}

export interface EngineEvents {
  /** A one-line readout after each DOM key event. */
  keys: string;
  /** The DVI frame count, each time it advances. */
  frame: number;
  audio: AudioDiagnostics;
}

/** stdout and stderr, buffered from before the VM exists. */
export interface ConsoleLog {
  write(line: string): void;
  lines(): readonly string[];
  /** How many lines the cap has evicted, so a reader can align its own work. */
  dropped(): number;
  subscribe(callback: (lines: readonly string[], dropped: number) => void): () => void;
}

/** One file in the MEMFS tree. */
export interface FileEntry {
  path: string;
  size: number;
}

export interface FileTree {
  files: FileEntry[];
  directories: string[];
}

/** What a batch of uploads did. */
export interface AddResult {
  written: string[];
  replaced: string[];
  failed: string[];
}

/** Anything with a name and bytes. A DOM File satisfies it, and so can a test. */
export interface UploadCandidate {
  name: string;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export interface Files {
  /** Write files into a directory, reporting what landed and what did not. */
  add(directory: string, files: UploadCandidate[]): Promise<AddResult>;
  tree(): FileTree;
  // Typed over a plain ArrayBuffer so the bytes can go straight into a Blob.
  read(path: string): Uint8Array<ArrayBuffer>;
}

export interface Engine {
  /** Init the VM, prune the emscripten-only dirs and start the run loop. */
  start(): void;
  /**
   * Run the callback once the VM is up and the rootfs is on MEMFS, immediately
   * if that has already happened. Returns an unsubscribe.
   */
  onReady(callback: () => void): () => void;
  on<E extends keyof EngineEvents>(event: E, callback: (value: EngineEvents[E]) => void): () => void;
  log: ConsoleLog | null;
  setPad(pad: number, dir: number, down: boolean): void;
  releasePads(): void;
  /** Arm Web Audio from a user gesture. */
  armAudio(): void;
  keyDown(usage: number): void;
  keyUp(usage: number): void;
  /** Latch the on-screen keyboard's modifier bits (HID mask). */
  setKeyModifier(mask: number): void;
  files: Files;
}

/** The emscripten Module. Only the engine touches its internals. */
export type HarucomModule = object;

export function createConsoleLog(options?: { limit?: number }): ConsoleLog {
  return createLog(options) as ConsoleLog;
}

export function createEngine(
  module: HarucomModule,
  options: { canvas: HTMLCanvasElement; log: ConsoleLog },
): Engine {
  // The JS module has no types, so TypeScript infers its `log = null` default
  // as the null type. Widen at this one boundary rather than annotate the JS.
  return (create as (m: HarucomModule, o: unknown) => Engine)(module, options);
}
