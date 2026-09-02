// The page shell: the screen, the pads, then the log.
import { useEffect, useRef } from "react";
import { Screen } from "./Screen";
import { Pads } from "./Pads";
import type { Engine } from "./engine";

// engine is null when the wasm module failed to load: the shell still renders so
// the log can say why, but there is nothing for the pads to talk to.
export function App({ canvas, engine, log }: { canvas: HTMLCanvasElement; engine: Engine | null; log: HTMLElement }) {
  const logHost = useRef<HTMLDivElement>(null);

  // The log element is created before the module boots so output from
  // harucom_init is captured, which is earlier than React can mount. Adopt it
  // here rather than rendering a fresh <pre> React would then have to fill.
  useEffect(() => {
    logHost.current?.appendChild(log);
  }, [log]);

  return (
    <div className="min-h-screen w-full bg-base text-fg flex flex-col items-center gap-4 py-8">
      <Screen canvas={canvas} />
      {engine && <Pads engine={engine} />}
      <div ref={logHost} className="w-[640px] max-w-full border border-border rounded-md overflow-hidden" />
    </div>
  );
}
