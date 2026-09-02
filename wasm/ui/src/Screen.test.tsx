// The engine holds a 2D context on this canvas, so React must host it without
// ever creating it. If Screen rendered its own <canvas>, every remount would
// hand the engine a dead context and the display would freeze.
import { describe, it, expect, vi } from "vitest";
import { render, act, screen } from "@testing-library/react";
import { Screen } from "./Screen";

describe("Screen", () => {
  it("hosts the canvas it was given rather than creating one", () => {
    const canvas = document.createElement("canvas");
    const { container } = render(<Screen canvas={canvas} />);
    expect(container.querySelectorAll("canvas")).toHaveLength(1);
    expect(container.querySelector("canvas")).toBe(canvas);
  });

  // Switching dock modes tears this subtree down and builds it again. The canvas
  // has to survive that, which is why it is a prop and not a lookup by id: once
  // detached, getElementById would no longer find it.
  it("puts the same canvas back after a remount", () => {
    const canvas = document.createElement("canvas");
    const first = render(<Screen canvas={canvas} />);
    first.unmount();
    const { container } = render(<Screen canvas={canvas} />);
    expect(container.querySelector("canvas")).toBe(canvas);
  });
});

// Fullscreen is what makes the browser build usable as a machine rather than a
// demo in a page: the OS gets the whole display and the keyboard with it.
describe("Screen fullscreen", () => {
  function stubFullscreen() {
    let element: Element | null = null;
    Object.defineProperty(document, "fullscreenElement", {
      configurable: true,
      get: () => element,
    });
    const enter = vi.fn(function (this: Element) {
      element = this;
      document.dispatchEvent(new Event("fullscreenchange"));
      return Promise.resolve();
    });
    Element.prototype.requestFullscreen = enter;
    document.exitFullscreen = vi.fn(() => {
      element = null;
      document.dispatchEvent(new Event("fullscreenchange"));
      return Promise.resolve();
    });
    return { enter };
  }

  it("asks for fullscreen on the frame, so the button goes with it", async () => {
    const { enter } = stubFullscreen();
    const canvas = document.createElement("canvas");
    const { container } = render(<Screen canvas={canvas} />);
    const button = screen.getByRole("button", { name: "Show the screen fullscreen" });
    await act(async () => button.click());
    expect(enter.mock.instances[0]).toBe(container.firstElementChild);
    expect(container.firstElementChild?.contains(button)).toBe(true);
  });

  // Escape and the browser's own control both leave fullscreen without going
  // through the button, so the label has to follow the document.
  it("follows the document when fullscreen ends elsewhere", async () => {
    stubFullscreen();
    render(<Screen canvas={document.createElement("canvas")} />);
    await act(async () => screen.getByRole("button", { name: "Show the screen fullscreen" }).click());
    expect(screen.getByRole("button", { name: "Leave fullscreen" })).toBeTruthy();
    await act(async () => {
      await document.exitFullscreen();
    });
    expect(screen.getByRole("button", { name: "Show the screen fullscreen" })).toBeTruthy();
  });

  it("moves focus to the canvas so keys reach the OS", async () => {
    stubFullscreen();
    const canvas = document.createElement("canvas");
    const focus = vi.spyOn(canvas, "focus");
    render(<Screen canvas={canvas} />);
    await act(async () => screen.getByRole("button", { name: "Show the screen fullscreen" }).click());
    expect(focus).toHaveBeenCalled();
  });
});
