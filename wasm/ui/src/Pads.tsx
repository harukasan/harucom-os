// Stand-ins for the board's two 4-way pads.
//
// The board wires each pad as a resistor ladder into the ADC. The browser has no
// ADC, so these buttons tell the engine which direction is down and it writes the
// value the ladder would have produced.
import { useEffect } from "react";
import type { Engine } from "./engine";

// dir values are the engine's: RIGHT=0 UP=1 DOWN=2 LEFT=3. Laid out as a cross.
const KEYS: { dir: number; label: string; column: number; row: number }[] = [
  { dir: 1, label: "↑", column: 2, row: 1 },
  { dir: 3, label: "←", column: 1, row: 2 },
  { dir: 0, label: "→", column: 3, row: 2 },
  { dir: 2, label: "↓", column: 2, row: 3 },
];

const KEY_CLASS =
  "w-10 h-10 rounded bg-pad text-fg text-lg flex items-center justify-center " +
  "select-none touch-none border border-border hover:bg-border-hover " +
  "active:bg-pad-on active:text-[#16161e]";

function Pad({ pad, engine }: { pad: number; engine: Engine }) {
  return (
    <div className="flex flex-col items-center gap-1">
      <div className="text-fg-dim text-xs">PAD{pad}</div>
      <div className="grid gap-1" style={{ gridTemplateColumns: "repeat(3, 2.5rem)", gridAutoRows: "2.5rem" }}>
        {KEYS.map(({ dir, label, column, row }) => (
          <button
            key={dir}
            type="button"
            className={KEY_CLASS}
            style={{ gridColumn: column, gridRow: row }}
            onPointerDown={(e) => {
              // Only the primary button. A right-click opens the context menu,
              // which can swallow the matching pointerup and leave the direction
              // latched down.
              if (e.button !== 0) return;
              // Capture keeps the release on this button even if the finger
              // slides off, so a direction cannot stay pressed.
              e.currentTarget.setPointerCapture(e.pointerId);
              engine.setPad(pad, dir, true);
              // On a touch device these buttons are the only input, and audio.js
              // listens only on the canvas and the keyboard, so arm from here as
              // well or audio_demo runs silently.
              engine.armAudio();
              e.preventDefault(); // do not steal focus from the screen
            }}
            onPointerUp={() => engine.setPad(pad, dir, false)}
            onPointerCancel={() => engine.setPad(pad, dir, false)}
            onContextMenu={(e) => e.preventDefault()}
          >
            {label}
          </button>
        ))}
      </div>
    </div>
  );
}

export function Pads({ engine }: { engine: Engine }) {
  // Losing the page can swallow the release entirely. Switching apps on a phone
  // fires visibilitychange without a window blur, so watch both, as keyboard.js
  // does for the physical keys.
  useEffect(() => {
    const releaseAll = () => engine.releasePads();
    const onVisibility = () => {
      if (document.hidden) releaseAll();
    };
    window.addEventListener("blur", releaseAll);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      window.removeEventListener("blur", releaseAll);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [engine]);

  return (
    <div className="flex gap-8">
      <Pad pad={0} engine={engine} />
      <Pad pad={1} engine={engine} />
    </div>
  );
}
