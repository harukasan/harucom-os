// The page shell and where the panel host sits.
//
// Three dock positions:
//   undocked  a normal, scrollable page: the screen, a fixed gap, then a panel
//             box the browser resizes natively by its bottom-right corner.
//   bottom    a full-height app, screen centred, panels filling the width below,
//             resized by the splitter between them.
//   right     the same with the panels beside the screen.
//
// The screen is remounted when the position changes. That is safe because the
// canvas is an element passed down rather than one React builds: the engine's 2D
// context is on that element and survives being moved.
import { useRef, useState } from "react";
import { Screen } from "./Screen";
import { Panels } from "./Panels";
import { Console } from "./Console";
import { clampDock, useDockResize } from "./useDockResize";
import type { ConsoleLog, Engine } from "./engine";
import type { DockPosition } from "./dock";

export function App({ canvas, engine, log }: { canvas: HTMLCanvasElement; engine: Engine | null; log: ConsoleLog }) {
  const [dock, setDock] = useState<DockPosition>("undocked");
  const [width, setWidth] = useState(384);   // right dock
  const [height, setHeight] = useState(256); // bottom dock
  const dockElement = useRef<HTMLDivElement>(null);
  const bottom = dock === "bottom";
  const resize = useDockResize(dockElement, bottom, bottom ? height : width,
                               (size) => (bottom ? setHeight(size) : setWidth(size)));

  // engine is null when the wasm module failed to load. The shell still renders
  // so the console can say why, but there is nothing for the panels to read.
  const body = engine
    ? <Panels engine={engine} log={log} dock={dock} onDock={setDock} />
    : <Console log={log} />;

  if (dock === "undocked") {
    return (
      <div className="min-h-screen w-full bg-base text-fg flex flex-col items-center py-8">
        <Screen canvas={canvas} />
        <div className="undock-box mt-10 border border-border rounded-md bg-panel-bg flex flex-col">
          {body}
        </div>
      </div>
    );
  }

  return (
    <div className={`h-screen w-screen bg-base text-fg flex overflow-hidden ${bottom ? "flex-col" : "flex-row"}`}>
      <div className="flex-1 grid place-items-center p-4 min-h-0 min-w-0 overflow-hidden">
        <Screen canvas={canvas} />
      </div>
      <div
        role="separator"
        aria-orientation={bottom ? "horizontal" : "vertical"}
        aria-label="Resize the panels"
        className={bottom
          ? "h-1.5 shrink-0 bg-border hover:bg-accent cursor-row-resize touch-none"
          : "w-1.5 shrink-0 bg-border hover:bg-accent cursor-col-resize touch-none"}
        {...resize}
      />
      <div
        ref={dockElement}
        className={`overflow-hidden bg-panel-bg shrink-0 ${bottom ? "border-t" : "border-l"} border-border`}
        style={bottom ? { height: clampDock(height) } : { width: clampDock(width) }}
      >
        {body}
      </div>
    </div>
  );
}
