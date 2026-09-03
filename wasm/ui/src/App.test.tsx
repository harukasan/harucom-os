import { describe, it, expect } from "vitest";
import { render, act, screen } from "@testing-library/react";
import { App } from "./App";
import { stubEngine } from "./test-engine";
import { createConsoleLog } from "./engine";
import { DOCK_MAX, DOCK_MIN } from "./useDockResize";

function setup() {
  const canvas = document.createElement("canvas");
  const log = createConsoleLog();
  const engine = stubEngine(log, {
    add: async () => ({ written: [], replaced: [], failed: [] }),
    tree: () => ({ files: [], directories: ["/", "/app", "/data"] }),
    read: () => new Uint8Array(new ArrayBuffer(0)),
  });
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
    grip.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true, pointerId: 1, button: 0, [axis]: from }));
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

  // The drag writes the size straight onto the element so a move does not
  // re-render, and commits it to state on release. A second drag measures from
  // that state, so this is what says the commit happened: without it the inline
  // style is all there is, and it is lost the next time App renders.
  it("starts a second drag from where the first one ended", () => {
    setup();
    dockTo("Dock the panels below");
    drag(400, 300, "clientY"); // 256 + 100
    expect(dock().style.height).toBe("356px");
    drag(400, 300, "clientY"); // 356 + 100, not 256 + 100 again
    expect(dock().style.height).toBe("456px");
  });

  // A right-press must not start a drag: the context menu can swallow the
  // pointerup, and with the pointer captured every later move would go on
  // resizing with no button held.
  it("ignores a drag started with a non-primary button", () => {
    setup();
    dockTo("Dock the panels below");
    const grip = screen.getByRole("separator");
    act(() => {
      grip.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true, pointerId: 1, button: 2, clientY: 400 }));
      grip.dispatchEvent(new window.PointerEvent("pointermove", { bubbles: true, pointerId: 1, clientY: 300 }));
    });
    expect(dock().style.height).toBe("256px");
  });

  it("clamps the dock so it cannot swallow or vanish behind the screen", () => {
    setup();
    dockTo("Dock the panels below");
    drag(400, 4000, "clientY"); // dragged far past the screen
    expect(dock().style.height).toBe(`${DOCK_MIN}px`);
    drag(400, -4000, "clientY");
    expect(dock().style.height).toBe(`${DOCK_MAX}px`);
  });

  // The transfer state is held above the panels so it survives them being
  // unmounted. React matches children by position, so a provider inside the body
  // was torn down on every dock switch: the report of what had just been
  // uploaded, which is the part a user is looking for, went with it.
  it("keeps the file transfer state across a dock switch", () => {
    setup();
    act(() => {
      screen.getByRole("button", { name: "Files" }).click();
    });
    const picker = screen.getByLabelText("Upload to") as HTMLSelectElement;
    act(() => {
      picker.value = "/app";
      picker.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    dockTo("Dock the panels below");
    expect((screen.getByLabelText("Upload to") as HTMLSelectElement).value).toBe("/app");
  });
});
