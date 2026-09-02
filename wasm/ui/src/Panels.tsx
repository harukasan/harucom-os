// The devtools-style panel host: a tab strip, and the active panel below it.
//
// Only the active panel is mounted. Anything a panel must not lose across a tab
// switch therefore lives in the engine, not in the panel (the console history is
// the reason that rule exists).
import { useState } from "react";
import { PANELS } from "./panels";
import type { ConsoleLog, Engine } from "./engine";

const TAB = "px-3 py-1.5 text-xs uppercase cursor-pointer whitespace-nowrap";
const TAB_ACTIVE = "text-tab-active bg-panel-bg";
const TAB_IDLE = "text-tab-inactive hover:text-fg hover:bg-panel-bg";

export function Panels({ engine, log }: { engine: Engine; log: ConsoleLog }) {
  const [active, setActive] = useState(PANELS[0].slug);
  const panel = PANELS.find((p) => p.slug === active) ?? PANELS[0];

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-stretch bg-bar-bg border-b border-border select-none">
        <div className="flex overflow-x-auto">
          {PANELS.map((p) => (
            <button
              key={p.slug}
              type="button"
              aria-current={p.slug === active}
              className={`${TAB} ${p.slug === active ? TAB_ACTIVE : TAB_IDLE}`}
              onClick={() => setActive(p.slug)}
            >
              {p.title}
            </button>
          ))}
        </div>
      </div>
      <div className="flex-1 overflow-auto bg-panel-bg min-h-0">
        <panel.Component engine={engine} log={log} />
      </div>
    </div>
  );
}
