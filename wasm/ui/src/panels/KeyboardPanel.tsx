// An on-screen keyboard, for a machine with no keyboard attached.
//
// Each key sends a momentary HID press through the engine, driving the same
// report as the physical keyboard, so the OS applies its own layout to the
// usage. Shift, Ctrl and Alt are latches rather than momentary: a tap holds the
// modifier until it is tapped again, which is the only way to reach a chord with
// one pointer. Left and right modifiers share a latch, since the OS does not
// distinguish them.
import { useEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import type { PanelDefinition, PanelProps } from "./types";

// HID modifier bits.
const SHIFT = 0x02;
const CTRL = 0x01;
const ALT = 0x04;

type Latch = "shift" | "ctrl" | "alt";
const LATCH_BIT: Record<Latch, number> = { shift: SHIFT, ctrl: CTRL, alt: ALT };

// [label, HID usage or latch name, width class]. The default is a square, and
// the wide keys are sized in units of that square plus its gap, so the rows line
// up the way a real keyboard's do.
type Key = [string, number | Latch, string?];

const ROWS: Key[][] = [
  [["Esc", 0x29], ["F1", 0x3a], ["F2", 0x3b], ["F3", 0x3c], ["F4", 0x3d], ["F5", 0x3e],
   ["F6", 0x3f], ["F7", 0x40], ["F8", 0x41], ["F9", 0x42], ["F10", 0x43], ["F11", 0x44], ["F12", 0x45]],
  [["`", 0x35], ["1", 0x1e], ["2", 0x1f], ["3", 0x20], ["4", 0x21], ["5", 0x22], ["6", 0x23],
   ["7", 0x24], ["8", 0x25], ["9", 0x26], ["0", 0x27], ["-", 0x2d], ["=", 0x2e], ["Bksp", 0x2a, "w-[4.75rem]"]],
  [["Tab", 0x2b, "w-[2.875rem]"], ["Q", 0x14], ["W", 0x1a], ["E", 0x08], ["R", 0x15], ["T", 0x17], ["Y", 0x1c],
   ["U", 0x18], ["I", 0x0c], ["O", 0x12], ["P", 0x13], ["[", 0x2f], ["]", 0x30], ["\\", 0x31, "w-[3.5rem]"]],
  [["Caps", 0x39, "w-[3.5rem]"], ["A", 0x04], ["S", 0x16], ["D", 0x07], ["F", 0x09], ["G", 0x0a], ["H", 0x0b],
   ["J", 0x0d], ["K", 0x0e], ["L", 0x0f], [";", 0x33], ["'", 0x34], ["Enter", 0x28, "w-[5.375rem]"]],
  [["Shift", "shift", "w-[4.125rem]"], ["Z", 0x1d], ["X", 0x1b], ["C", 0x06], ["V", 0x19], ["B", 0x05], ["N", 0x11],
   ["M", 0x10], [",", 0x36], [".", 0x37], ["/", 0x38], ["Shift", "shift", "w-[4.125rem]"]],
  [["Ctrl", "ctrl", "w-[2.875rem]"], ["Alt", "alt", "w-[2.875rem]"], ["Space", 0x2c, "flex-1"],
   ["Alt", "alt", "w-[2.875rem]"], ["Ctrl", "ctrl", "w-[2.875rem]"]],
  [["Ins", 0x49], ["Home", 0x4a], ["PgUp", 0x4b], ["Del", 0x4c], ["End", 0x4d], ["PgDn", 0x4e],
   ["←", 0x50], ["↑", 0x52], ["↓", 0x51], ["→", 0x4f]],
];

const KEY = "h-9 rounded text-xs flex items-center justify-center touch-none border border-border";
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
      {ROWS.map((row, index) => (
        <div key={index} className="flex gap-1 mb-1 whitespace-nowrap">
          {row.map(([label, action, width], column) => (
            typeof action === "number" ? (
              <button
                key={column}
                type="button"
                className={`${KEY} ${KEY_IDLE} ${width ?? "w-9"}`}
                onPointerDown={(e) => press(action, e)}
                onPointerUp={release}
                onPointerCancel={release}
              >
                {label}
              </button>
            ) : (
              <button
                key={column}
                type="button"
                aria-pressed={latched[action]}
                className={`${KEY} ${latched[action] ? KEY_LATCHED : KEY_IDLE} ${width ?? "w-9"}`}
                onClick={() => setLatched((held) => ({ ...held, [action]: !held[action] }))}
              >
                {label}
              </button>
            )
          ))}
        </div>
      ))}
    </div>
  );
}

export const keyboardPanel: PanelDefinition = {
  slug: "keyboard",
  title: "Keyboard",
  Component: KeyboardPanel,
};
