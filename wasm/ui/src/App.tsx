// The page shell: the screen, the pads, then the console.
import { Screen } from "./Screen";
import { Pads } from "./Pads";
import { Console } from "./Console";
import type { ConsoleLog, Engine } from "./engine";

// engine is null when the wasm module failed to load: the shell still renders so
// the console can say why, but there is nothing for the pads to talk to.
export function App({ canvas, engine, log }: { canvas: HTMLCanvasElement; engine: Engine | null; log: ConsoleLog }) {
  return (
    <div className="min-h-screen w-full bg-base text-fg flex flex-col items-center gap-4 py-8">
      <Screen canvas={canvas} />
      {engine && <Pads engine={engine} />}
      <div className="w-[640px] max-w-full h-64 border border-border rounded-md overflow-hidden">
        <Console log={log} />
      </div>
    </div>
  );
}
