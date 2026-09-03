// The devtools-style panel host: a tab strip, and the active panel below it.
//
// Only the active panel is mounted. Anything a panel must not lose across a tab
// switch therefore lives in the engine, not in the panel (the console history is
// the reason that rule exists).
import { PANELS } from "./panels";
import { DOCK_CHOICES, type DockPosition } from "./dock";
import type { ConsoleLog, Engine } from "./engine";

const TAB = "px-3 py-1.5 text-xs uppercase cursor-pointer whitespace-nowrap";
const TAB_ACTIVE = "text-tab-active bg-panel-bg";
const TAB_IDLE = "text-tab-inactive hover:text-fg hover:bg-panel-bg";

export function Panels({ engine, log, dock, onDock, active, onActive }: {
  engine: Engine;
  log: ConsoleLog;
  dock: DockPosition;
  onDock: (position: DockPosition) => void;
  /** Owned by the shell, so a dropped file can bring the Files panel forward. */
  active: string;
  onActive: (slug: string) => void;
}) {
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
              onClick={() => onActive(p.slug)}
            >
              {p.title}
            </button>
          ))}
        </div>
        {/* The dock buttons report a position up to the App, which owns it: the
            layout around this host is not this host's to change. */}
        <div className="ml-auto flex items-center">
          {DOCK_CHOICES.map(({ position, label, glyph }) => (
            <button
              key={position}
              type="button"
              title={label}
              aria-label={label}
              aria-pressed={position === dock}
              className={`px-2 flex items-center text-sm cursor-pointer leading-none ${
                position === dock ? "text-tab-active" : "text-tab-inactive hover:text-fg"}`}
              onClick={() => onDock(position)}
            >
              {glyph}
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
