// An on-screen keyboard, for a machine with no keyboard attached.
//
// Each key sends a momentary HID press through the engine, driving the same
// report as the physical keyboard, so the OS applies its own layout to the
// usage. Shift, Ctrl and Alt are latches rather than momentary: a tap holds the
// modifier until it is tapped again, which is the only way to reach a chord with
// one pointer. Left and right modifiers share a latch, since the OS does not
// distinguish them.
//
// The layout is a grid of quarter-units, the way keyboard sizes are actually
// specified: a row is 15u wide, a plain key is 1u, and the wide keys are the
// standard ANSI sizes (Tab 1.5u, Caps 1.75u, Enter 2.25u, right Shift 2.75u).
// Every row therefore adds up to the same width and the columns line up down the
// board, which hand-picked pixel widths never quite manage. The gap comes from a
// margin on each key rather than from the grid, because a gap between all sixty
// columns would be wider than the keys.
import { useEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import type { PanelDefinition, PanelProps } from "./types";

// HID modifier bits.
const SHIFT = 0x02;
const CTRL = 0x01;
const ALT = 0x04;

type Latch = "shift" | "ctrl" | "alt";
const LATCH_BIT: Record<Latch, number> = { shift: SHIFT, ctrl: CTRL, alt: ALT };

const COLUMNS = 60; // 15u at quarter-unit resolution
const U = 4;        // columns in one unit

// [label, HID usage or latch name, width in columns]. null is a gap: the space
// between Esc and F1, or between the navigation keys and the arrows.
type Key = [string | null, number | Latch | null, number?];

const ROWS: Key[][] = [
  [["Esc", 0x29], [null, null, U], ["F1", 0x3a], ["F2", 0x3b], ["F3", 0x3c], ["F4", 0x3d],
   [null, null, 2], ["F5", 0x3e], ["F6", 0x3f], ["F7", 0x40], ["F8", 0x41],
   [null, null, 2], ["F9", 0x42], ["F10", 0x43], ["F11", 0x44], ["F12", 0x45]],
  [["`", 0x35], ["1", 0x1e], ["2", 0x1f], ["3", 0x20], ["4", 0x21], ["5", 0x22], ["6", 0x23],
   ["7", 0x24], ["8", 0x25], ["9", 0x26], ["0", 0x27], ["-", 0x2d], ["=", 0x2e], ["Bksp", 0x2a, 8]],
  [["Tab", 0x2b, 6], ["Q", 0x14], ["W", 0x1a], ["E", 0x08], ["R", 0x15], ["T", 0x17], ["Y", 0x1c],
   ["U", 0x18], ["I", 0x0c], ["O", 0x12], ["P", 0x13], ["[", 0x2f], ["]", 0x30], ["\\", 0x31, 6]],
  [["Caps", 0x39, 7], ["A", 0x04], ["S", 0x16], ["D", 0x07], ["F", 0x09], ["G", 0x0a], ["H", 0x0b],
   ["J", 0x0d], ["K", 0x0e], ["L", 0x0f], [";", 0x33], ["'", 0x34], ["Enter", 0x28, 9]],
  [["Shift", "shift", 9], ["Z", 0x1d], ["X", 0x1b], ["C", 0x06], ["V", 0x19], ["B", 0x05], ["N", 0x11],
   ["M", 0x10], [",", 0x36], [".", 0x37], ["/", 0x38], ["Shift", "shift", 11]],
  [["Ctrl", "ctrl", 6], ["Alt", "alt", 6], ["Space", 0x2c, 36], ["Alt", "alt", 6], ["Ctrl", "ctrl", 6]],
  [["Ins", 0x49, 6], ["Home", 0x4a, 6], ["PgUp", 0x4b, 6], ["Del", 0x4c, 6], ["End", 0x4d, 6],
   ["PgDn", 0x4e, 6], [null, null, U], ["←", 0x50, 5], ["↑", 0x52, 5], ["↓", 0x51, 5], ["→", 0x4f, 5]],
];

const KEY = "h-8 m-[2px] rounded text-[11px] leading-none flex items-center justify-center " +
            "touch-none border border-border overflow-hidden";
const KEY_IDLE = "bg-pad text-fg hover:bg-border-hover active:bg-pad-on active:text-[#16161e]";
const KEY_LATCHED = "bg-pad-on text-[#16161e]";

function KeyboardPanel({ engine }: PanelProps) {
  const [latched, setLatched] = useState<Record<Latch, boolean>>({ shift: false, ctrl: false, alt: false });
  // Which usage each pointer is holding. A map rather than one slot because this
  // panel exists for a machine with no keyboard, which means touch, where typing
  // with two thumbs is normal: with a single slot, pressing A then B and lifting
  // A would send the release for B and leave A held, and the OS repeats from the
  // held state. A ref rather than state because nothing renders from it (the
  // pressed look is the CSS :active state) and the unmount cleanup has to read
  // the current value, not the one captured when the effect was set up.
  const pressed = useRef(new Map<number, number>());

  // Push the combined latch mask down whenever it changes, so it applies to
  // every key pressed afterwards, including physical ones.
  useEffect(() => {
    let mask = 0;
    for (const name of Object.keys(LATCH_BIT) as Latch[]) if (latched[name]) mask |= LATCH_BIT[name];
    engine.setKeyModifier(mask);
  }, [engine, latched]);

  // Anything still held when this panel goes away (the tab is switched, the
  // shell is torn down) would never see its release: the OS would repeat the key
  // forever, and every later physical key would carry the latched modifiers,
  // with nothing on screen to say why.
  useEffect(() => () => {
    const held = pressed.current;
    for (const usage of held.values()) engine.keyUp(usage);
    held.clear();
    engine.setKeyModifier(0);
  }, [engine]);

  function press(usage: number, e: ReactPointerEvent<HTMLButtonElement>) {
    // Capture so a press that slides off the key still releases on this button.
    e.currentTarget.setPointerCapture(e.pointerId);
    e.preventDefault(); // do not take focus away from the screen
    pressed.current.set(e.pointerId, usage);
    engine.keyDown(usage);
  }

  // Release what this pointer took, not what is under it now, so a press that
  // ends off its key still lifts and a second finger does not release the first
  // finger's key.
  function release(e: ReactPointerEvent<HTMLButtonElement>) {
    const usage = pressed.current.get(e.pointerId);
    if (usage === undefined) return;
    pressed.current.delete(e.pointerId);
    engine.keyUp(usage);
  }

  return (
    <div className="p-2 select-none overflow-x-auto">
      <div className="w-[30rem] min-w-[30rem]">
        {ROWS.map((row, index) => (
          <div
            key={index}
            className="grid"
            style={{ gridTemplateColumns: `repeat(${COLUMNS}, minmax(0, 1fr))` }}
          >
            {row.map(([label, action, span = U], column) => {
              const style = { gridColumn: `span ${span}` };
              if (action === null) return <div key={column} style={style} />;
              if (typeof action === "number") {
                return (
                  <button
                    key={column}
                    type="button"
                    style={style}
                    className={`${KEY} ${KEY_IDLE}`}
                    onPointerDown={(e) => press(action, e)}
                    onPointerUp={release}
                    onPointerCancel={release}
                  >
                    {label}
                  </button>
                );
              }
              return (
                <button
                  key={column}
                  type="button"
                  style={style}
                  aria-pressed={latched[action]}
                  className={`${KEY} ${latched[action] ? KEY_LATCHED : KEY_IDLE}`}
                  onClick={() => setLatched((held) => ({ ...held, [action]: !held[action] }))}
                >
                  {label}
                </button>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}

export const keyboardPanel: PanelDefinition = {
  slug: "keyboard",
  title: "Keyboard",
  Component: KeyboardPanel,
};
