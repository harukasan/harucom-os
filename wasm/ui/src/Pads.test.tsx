import { describe, it, expect, vi } from "vitest";
import { render, fireEvent } from "@testing-library/react";
import { Pads } from "./Pads";
import { stubEngine } from "./test-engine";

// The arrow order follows KEYS: up, left, right, down.
function buttons(container: HTMLElement) {
  return Array.from(container.querySelectorAll("button"));
}

// Each button names the pad it belongs to, so the two pads are distinguishable
// to a screen reader and to a test.


describe("Pads", () => {
  it("presses and releases the direction the button stands for", () => {
    const engine = stubEngine();
    const { container } = render(<Pads engine={engine} />);
    const up = buttons(container)[0]; // PAD0, up
    fireEvent.pointerDown(up, { button: 0, pointerId: 1 });
    expect(engine.setPad).toHaveBeenCalledWith(0, 1, true);
    fireEvent.pointerUp(up, { pointerId: 1 });
    expect(engine.setPad).toHaveBeenCalledWith(0, 1, false);
  });

  it("drives the second pad as pad 1", () => {
    const engine = stubEngine();
    const { container } = render(<Pads engine={engine} />);
    fireEvent.pointerDown(buttons(container)[4], { button: 0, pointerId: 1 }); // PAD1, up
    expect(engine.setPad).toHaveBeenCalledWith(1, 1, true);
  });

  // A right-click opens the context menu, which can swallow the matching
  // pointerup. Pressing on it would leave the direction latched down with no
  // release coming.
  it("ignores a non-primary button", () => {
    const engine = stubEngine();
    const { container } = render(<Pads engine={engine} />);
    fireEvent.pointerDown(buttons(container)[0], { button: 2, pointerId: 1 });
    expect(engine.setPad).not.toHaveBeenCalled();
  });

  // On a touch device these buttons are the only input, and audio.js listens
  // only on the canvas and the keyboard, so without this audio_demo is silent.
  it("arms audio from a press, since a pad tap may be the only gesture", () => {
    const engine = stubEngine();
    const { container } = render(<Pads engine={engine} />);
    fireEvent.pointerDown(buttons(container)[0], { button: 0, pointerId: 1 });
    expect(engine.armAudio).toHaveBeenCalled();
  });

  // Losing the page can swallow the release entirely, leaving a direction held.
  it("releases everything when the page loses focus or is hidden", () => {
    const engine = stubEngine();
    render(<Pads engine={engine} />);
    window.dispatchEvent(new Event("blur"));
    expect(engine.releasePads).toHaveBeenCalledTimes(1);

    vi.spyOn(document, "hidden", "get").mockReturnValue(true);
    document.dispatchEvent(new Event("visibilitychange"));
    expect(engine.releasePads).toHaveBeenCalledTimes(2);
  });
});
