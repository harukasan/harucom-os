import { describe, it, expect, vi } from "vitest";
import { render, act, screen } from "@testing-library/react";
import { Panels } from "./Panels";
import { stubEngine } from "./test-engine";
import { createConsoleLog } from "./engine";

function setup(onDock = vi.fn()) {
  const log = createConsoleLog();
  const engine = stubEngine(log);
  return { engine, log, onDock, ...render(<Panels engine={engine} log={log} dock="undocked" onDock={onDock} />) };
}

describe("Panels", () => {
  it("opens on the first tab", () => {
    setup();
    expect(screen.getByRole("button", { name: "Console" }).getAttribute("aria-current")).toBe("true");
  });

  it("switches the body when another tab is chosen", () => {
    const { engine } = setup();
    act(() => {
      screen.getByRole("button", { name: "Status" }).click();
    });
    expect(screen.getByText("(none yet)")).toBeTruthy();
    act(() => engine.emit("keys", "code=KeyA usage=0x4"));
    expect(screen.getByText(/code=KeyA/)).toBeTruthy();
  });

  // Only the active panel is mounted, so anything a panel must keep across a tab
  // switch has to live in the engine. The console history is the case that
  // proves it: it is written while the console tab is not even open.
  it("keeps console output written while another tab was showing", () => {
    const { log } = setup();
    act(() => {
      screen.getByRole("button", { name: "Status" }).click();
    });
    act(() => log.write("printed while away"));
    act(() => {
      screen.getByRole("button", { name: "Console" }).click();
    });
    expect(screen.getByText("printed while away")).toBeTruthy();
  });

  // The pads are the only input on a touch device, so losing them from the tab
  // list would leave such a device with no way to drive an app that reads them.
  it("offers the pads as a tab", () => {
    const { engine } = setup();
    act(() => {
      screen.getByRole("button", { name: "Pads" }).click();
    });
    act(() => {
      screen.getByRole("button", { name: "PAD0 up" }).dispatchEvent(
        new window.PointerEvent("pointerdown", { bubbles: true, button: 0, pointerId: 1 }));
    });
    expect(engine.setPad).toHaveBeenCalledWith(0, 1, true);
  });

  it("shows the frame count the engine reports", () => {
    const { engine } = setup();
    act(() => {
      screen.getByRole("button", { name: "Status" }).click();
    });
    act(() => engine.emit("frame", 60));
    expect(screen.getByText("60")).toBeTruthy();
  });

  // Sampling is why the number climbs in steps rather than smoothly: rendering
  // sixty times a second would spend the idle budget on a digit nobody reads
  // that closely.
  it("samples the frame count instead of following every frame", () => {
    const { engine } = setup();
    act(() => {
      screen.getByRole("button", { name: "Status" }).click();
    });
    act(() => engine.emit("frame", 30));
    act(() => engine.emit("frame", 31));
    expect(screen.getByText("30")).toBeTruthy();
  });

  // Zeros would read as a healthy worklet rather than one that has not started,
  // and audio only starts on a user gesture.
  it("says audio has not started until the worklet reports", () => {
    const { engine } = setup();
    act(() => {
      screen.getByRole("button", { name: "Status" }).click();
    });
    expect(screen.getByText("not started")).toBeTruthy();
    act(() => engine.emit("audio", { level: 2048, underruns: 0, dropped: 0 }));
    expect(screen.getByText("running")).toBeTruthy();
    expect(screen.getByText("2048")).toBeTruthy();
  });

  // The host draws the dock buttons but does not act on them: the layout around
  // it belongs to the App, so the choice is reported upward.
  it("reports a dock choice rather than acting on it", () => {
    const { onDock } = setup();
    act(() => {
      screen.getByRole("button", { name: "Dock the panels below" }).click();
    });
    expect(onDock).toHaveBeenCalledWith("bottom");
  });

  it("marks the current dock position", () => {
    setup();
    expect(screen.getByRole("button", { name: "Undock the panels" }).getAttribute("aria-pressed")).toBe("true");
    expect(screen.getByRole("button", { name: "Dock the panels below" }).getAttribute("aria-pressed")).toBe("false");
  });
});
