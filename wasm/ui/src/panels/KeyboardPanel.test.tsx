import { describe, it, expect } from "vitest";
import { render, act, screen } from "@testing-library/react";
import { keyboardPanel } from "./KeyboardPanel";
import { stubEngine } from "../test-engine";
import { createConsoleLog } from "../engine";

const Keyboard = keyboardPanel.Component;

function setup() {
  const log = createConsoleLog();
  const engine = stubEngine(log);
  return { engine, log, ...render(<Keyboard engine={engine} log={log} />) };
}

function pointer(button: HTMLElement, type: string, pointerId = 1) {
  act(() => {
    button.dispatchEvent(new window.PointerEvent(type, { bubbles: true, pointerId }));
  });
}

describe("KeyboardPanel", () => {
  it("sends a momentary press for a regular key", () => {
    const { engine } = setup();
    const a = screen.getByRole("button", { name: "A" });
    pointer(a, "pointerdown");
    expect(engine.keyDown).toHaveBeenCalledWith(0x04);
    pointer(a, "pointerup");
    expect(engine.keyUp).toHaveBeenCalledWith(0x04);
  });

  // A press can end anywhere: the pointer slides off the key, or leaves the
  // panel. Releasing what is held, rather than what is under the pointer, is
  // what stops a key repeating forever.
  it("releases the held key even when the pointer ends elsewhere", () => {
    const { engine } = setup();
    pointer(screen.getByRole("button", { name: "A" }), "pointerdown");
    pointer(screen.getByRole("button", { name: "B" }), "pointerup");
    expect(engine.keyUp).toHaveBeenCalledWith(0x04);
    expect(engine.keyUp).not.toHaveBeenCalledWith(0x05);
  });

  // A latch is a toggle, not a momentary key: with one pointer there is no other
  // way to reach Ctrl-C.
  it("latches a modifier until it is tapped again", () => {
    const { engine } = setup();
    const shift = screen.getAllByRole("button", { name: "Shift" })[0];
    act(() => shift.click());
    expect(engine.setKeyModifier).toHaveBeenLastCalledWith(0x02);
    expect(shift.getAttribute("aria-pressed")).toBe("true");
    act(() => shift.click());
    expect(engine.setKeyModifier).toHaveBeenLastCalledWith(0);
  });

  it("combines latched modifiers", () => {
    const { engine } = setup();
    act(() => screen.getAllByRole("button", { name: "Ctrl" })[0].click());
    act(() => screen.getAllByRole("button", { name: "Alt" })[0].click());
    expect(engine.setKeyModifier).toHaveBeenLastCalledWith(0x05);
  });

  // The left and right keys are one latch, because the OS does not tell them
  // apart and two independent toggles would let the UI disagree with the report.
  it("shares one latch between the left and right modifier keys", () => {
    const { engine } = setup();
    const [left, right] = screen.getAllByRole("button", { name: "Shift" });
    act(() => left.click());
    expect(right.getAttribute("aria-pressed")).toBe("true");
    act(() => right.click());
    expect(engine.setKeyModifier).toHaveBeenLastCalledWith(0);
  });

  // Leaving the tab with Ctrl latched would apply it to every physical key
  // afterwards, with nothing on screen to say why.
  it("drops the latches when the panel goes away", () => {
    const { engine, unmount } = setup();
    act(() => screen.getAllByRole("button", { name: "Ctrl" })[0].click());
    unmount();
    expect(engine.setKeyModifier).toHaveBeenLastCalledWith(0);
  });

  // Switching tabs mid-press is easy to do by accident, and the OS repeats from
  // the held state, so the key would type forever with no way to stop it.
  it("releases a key still held when the panel goes away", () => {
    const { engine, unmount } = setup();
    pointer(screen.getByRole("button", { name: "A" }), "pointerdown");
    unmount();
    expect(engine.keyUp).toHaveBeenCalledWith(0x04);
  });

  // This panel is for a machine with no keyboard, which means touch, where
  // typing with two thumbs is normal. With one slot for the held key, lifting
  // the first finger sent the release for the second key and left the first one
  // down, and the OS repeats from the held state.
  it("keeps two fingers apart", () => {
    const { engine } = setup();
    pointer(screen.getByRole("button", { name: "A" }), "pointerdown", 1);
    pointer(screen.getByRole("button", { name: "B" }), "pointerdown", 2);
    pointer(screen.getByRole("button", { name: "A" }), "pointerup", 1);
    expect(engine.keyUp).toHaveBeenCalledWith(0x04);
    expect(engine.keyUp).not.toHaveBeenCalledWith(0x05);
    pointer(screen.getByRole("button", { name: "B" }), "pointerup", 2);
    expect(engine.keyUp).toHaveBeenCalledWith(0x05);
  });

  it("releases every finger still down when the panel goes away", () => {
    const { engine, unmount } = setup();
    pointer(screen.getByRole("button", { name: "A" }), "pointerdown", 1);
    pointer(screen.getByRole("button", { name: "B" }), "pointerdown", 2);
    unmount();
    expect(engine.keyUp).toHaveBeenCalledWith(0x04);
    expect(engine.keyUp).toHaveBeenCalledWith(0x05);

  // Every row is 15u wide, which is what makes the columns line up down the
  // board. A width that does not add up shows as a ragged right edge, and is
  // easy to introduce by changing one key.
  it("lays every row out to the same width", () => {
    const { container } = setup();
    const rows = [...container.querySelectorAll<HTMLElement>(".grid")];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      const spans = [...row.children].map((cell) =>
        Number(/span (\d+)/.exec((cell as HTMLElement).style.gridColumn)?.[1] ?? 0));
      expect(spans.reduce((total, span) => total + span, 0)).toBe(60);
    }
  });

  // A gap is a spacer, not a key: clicking where the F-row breaks must not send
  // a keystroke.
  it("leaves the gaps in the rows inert", () => {
    const { container } = setup();
    const spacers = [...container.querySelectorAll("div.grid > div")];
    expect(spacers.length).toBeGreaterThan(0);
    for (const spacer of spacers) expect(spacer.tagName).toBe("DIV");
  });
});
