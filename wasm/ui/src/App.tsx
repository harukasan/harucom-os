// The page shell: the screen, the pads, then the panel host.
import { Screen } from "./Screen";
import { Panels } from "./Panels";
import { Console } from "./Console";
import type { ConsoleLog, Engine } from "./engine";

// engine is null when the wasm module failed to load. The shell still renders so
// the console can say why, but there is nothing for the panels to read.
export function App({ canvas, engine, log }: { canvas: HTMLCanvasElement; engine: Engine | null; log: ConsoleLog }) {
  return (
    <div className="min-h-screen w-full bg-base text-fg flex flex-col items-center py-8">
      <Screen canvas={canvas} />
      <div className="mt-10 w-[640px] max-w-full h-80 border border-border rounded-md bg-panel-bg flex flex-col overflow-hidden">
        {engine ? <Panels engine={engine} log={log} /> : <Console log={log} />}
      </div>
    </div>
  );
}
