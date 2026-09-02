import { describe, it, expect } from "vitest";
import { render, act } from "@testing-library/react";
import { Console } from "./Console";
import { createConsoleLog } from "./engine";

describe("Console", () => {
  it("shows what was printed before it mounted", () => {
    const log = createConsoleLog();
    log.write("boot");
    log.write("ready");
    const { container } = render(<Console log={log} />);
    expect(container.textContent).toBe("boot\nready");
  });

  it("appends lines printed while it is mounted", () => {
    const log = createConsoleLog();
    const { container } = render(<Console log={log} />);
    act(() => log.write("later"));
    expect(container.textContent).toBe("later");
  });

  // The buffer is capped, and the panel renders all of it, so the oldest lines
  // have to fall off the top rather than grow without bound.
  it("shows only the lines the log still holds", () => {
    const log = createConsoleLog({ limit: 2 });
    const { container } = render(<Console log={log} />);
    act(() => {
      log.write("a");
      log.write("b");
      log.write("c");
    });
    expect(container.textContent).toBe("b\nc");
  });
});
