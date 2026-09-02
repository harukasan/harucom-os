import { describe, it, expect } from "vitest";
import { render, act, screen } from "@testing-library/react";
import { App } from "./App";
import { stubEngine } from "./test-engine";
import { createConsoleLog } from "./engine";
import { DOCK_MAX, DOCK_MIN } from "./useDockResize";

function setup() {
  const canvas = document.createElement("canvas");
  const log = createConsoleLog();
  const engine = stubEngine(log);
  return { canvas, engine, log, ...render(<App canvas={canvas} engine={engine} log={log} />) };
}

function dockTo(label: string) {
  act(() => {
    screen.getByRole("button", { name: label }).click();
  });
}

const dock = () => document.querySelector("[role=separator]")?.nextElementSibling as HTMLElement;

function drag(from: number, to: number, axis: "clientX" | "clientY") {
  const grip = screen.getByRole("separator");
  act(() => {
    grip.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true, pointerId: 1, [axis]: from }));
    grip.dispatchEvent(new window.PointerEvent("pointermove", { bubbles: true, pointerId: 1, [axis]: to }));
    grip.dispatchEvent(new window.PointerEvent("pointerup", { bubbles: true, pointerId: 1, [axis]: to }));
  });
}

describe("App", () => {
  it("starts undocked, with no splitter to drag", () => {
    setup();
    expect(document.querySelector(".undock-box")).toBeTruthy();
    expect(screen.queryByRole("separator")).toBeNull();
  });

  it("puts the panels below the screen when docked to the bottom", () => {
    setup();
    dockTo("Dock the panels below");
    expect(screen.getByRole("separator").getAttribute("aria-orientation")).toBe("horizontal");
    expect(dock().style.height).toBe("256px");
  });

  it("puts the panels beside the screen when docked to the right", () => {
    setup();
    dockTo("Dock the panels to the right");
    expect(screen.getByRole("separator").getAttribute("aria-orientation")).toBe("vertical");
    expect(dock().style.width).toBe("384px");
  });

  // The canvas carries the engine's 2D context. Losing it on a dock switch would
  // freeze the display with no error to show for it.
  it("keeps the same canvas across a dock switch", () => {
    const { canvas } = setup();
    dockTo("Dock the panels below");
    expect(document.querySelector("canvas")).toBe(canvas);
    dockTo("Undock the panels");
    expect(document.querySelector("canvas")).toBe(canvas);
  });

  // Dragging the inner edge toward the screen grows the dock.
  it("grows the dock when the splitter is dragged toward the screen", () => {
    setup();
    dockTo("Dock the panels below");
    drag(400, 300, "clientY");
    expect(dock().style.height).toBe("356px"); // 256 + 100
  });

  it("clamps the dock so it cannot swallow or vanish behind the screen", () => {
    setup();
    dockTo("Dock the panels below");
    drag(400, 4000, "clientY"); // dragged far past the screen
    expect(dock().style.height).toBe(`${DOCK_MIN}px`);
    drag(400, -4000, "clientY");
    expect(dock().style.height).toBe(`${DOCK_MAX}px`);
  });
});
