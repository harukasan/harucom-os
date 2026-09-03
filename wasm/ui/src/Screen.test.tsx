// The engine holds a 2D context on this canvas, so React must host it without
// ever creating it. If Screen rendered its own <canvas>, every remount would
// hand the engine a dead context and the display would freeze.
import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import { Screen } from "./Screen";

describe("Screen", () => {
  it("hosts the canvas it was given rather than creating one", () => {
    const canvas = document.createElement("canvas");
    const { container } = render(<Screen canvas={canvas} />);
    expect(container.querySelectorAll("canvas")).toHaveLength(1);
    expect(container.firstElementChild?.firstElementChild).toBe(canvas);
  });

  // Switching dock modes tears this subtree down and builds it again. The canvas
  // has to survive that, which is why it is a prop and not a lookup by id: once
  // detached, getElementById would no longer find it.
  it("puts the same canvas back after a remount", () => {
    const canvas = document.createElement("canvas");
    const first = render(<Screen canvas={canvas} />);
    first.unmount();
    const { container } = render(<Screen canvas={canvas} />);
    expect(container.firstElementChild?.firstElementChild).toBe(canvas);
  });
});
