import { describe, it, expect } from "vitest";
import { render, act } from "@testing-library/react";
import { renderToStaticMarkup } from "react-dom/server";
import { Console, update } from "./Console";
import { createConsoleLog } from "./engine";

const ESC = "\u001b";

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

  // The lazy initial state covers the first mount. This covers the other way in:
  // a different log arriving as a prop, where the initialiser does not re-run.
  it("follows a log it is handed later", () => {
    const first = createConsoleLog();
    first.write("old");
    const second = createConsoleLog();
    second.write("new");
    const { container, rerender } = render(<Console log={first} />);
    rerender(<Console log={second} />);
    expect(container.textContent).toBe("new");
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

  // Each line is parsed once and the result kept. The window sliding must not
  // change what the lines it still holds look like: each was parsed from the
  // state its own predecessor left, which dropping an earlier line cannot alter.
  it("shows the same colours after the cap has slid the window", () => {
    const log = createConsoleLog({ limit: 3 });
    const { container } = render(<Console log={log} />);
    act(() => {
      log.write(`${ESC}[34mblue`);   // opens a colour and never closes it
      log.write("still blue");
      log.write("also blue");
      log.write("pushed the first one out");
    });
    const coloured = [...container.querySelectorAll("span[class]")]
      .map((el) => el.textContent);
    expect(container.textContent).toBe("still blue\nalso blue\npushed the first one out");
    // The colour opened on the evicted line still applies to what follows it.
    expect(coloured.join("|")).toContain("still blue");
  });

  // A second log is not the first one with more lines in it, so nothing parsed
  // for the first may be reused.
  it("starts over when it is handed a different log", () => {
    const first = createConsoleLog();
    first.write(`${ESC}[31mred`);
    const second = createConsoleLog();
    second.write("plain");
    const { container, rerender } = render(<Console log={first} />);
    rerender(<Console log={second} />);
    expect(container.textContent).toBe("plain");
    expect(container.querySelectorAll("span[class]").length).toBe(0);
  });

  // The parse has to outlive the panel. Switching tabs unmounts the console, and
  // the colour a surviving line inherits was opened on a line the cap has since
  // dropped, so a cache that starts over on mount cannot work it out again.
  it("keeps an inherited colour across a remount", () => {
    const log = createConsoleLog({ limit: 3 });
    act(() => {
      log.write(`${ESC}[34mblue`);
      log.write("still blue");
      log.write("also blue");
      log.write("pushed the first one out");
    });
    const first = render(<Console log={log} />);
    const before = first.container.querySelectorAll("span[class]").length;
    first.unmount();
    const { container } = render(<Console log={log} />);
    expect(container.querySelectorAll("span[class]").length).toBe(before);
    expect(before).toBeGreaterThan(0);
  });

  // React matches children by key. Under the cap every index holds a different
  // line after each print, so index keys would have it rewrite the whole pane
  // for one appended line, which is the cost this was meant to remove.
  it("keys a line by where it sits in the whole output", () => {
    const log = createConsoleLog({ limit: 2 });
    const { container } = render(<Console log={log} />);
    act(() => {
      log.write("one");
      log.write("two");
    });
    // The node "two" is rendered into while it sits at index 1.
    const two = container.querySelector("pre")!.children[1];
    act(() => log.write("three"));
    // The cap pushed "one" out, so "two" is now at index 0. Keyed by where it
    // sits in the whole output, React moves the node it already had rather than
    // rewriting every line in the pane.
    expect(container.querySelector("pre")!.children[0]).toBe(two);
    expect(container.textContent).toBe("two\nthree");
  });

  // A log rewritten in place keeps its length, so a cache that compared only
  // lengths would leave the previous contents on screen for ever.
  it("re-reads lines whose text changed under it", () => {
    const log = createConsoleLog();
    log.write("first");
    const { container, rerender } = render(<Console log={log} />);
    expect(container.textContent).toBe("first");
    const replaced = createConsoleLog();
    replaced.write("second");
    rerender(<Console log={replaced} />);
    expect(container.textContent).toBe("second");
  });

  // useEffect runs after the browser paints, so a console filled by one would
  // show an empty pane for a frame on every tab switch. renderToStaticMarkup
  // runs no effects, which is the first paint.
  it("has the history in its very first render", () => {
    const log = createConsoleLog();
    log.write("printed before the panel opened");
    expect(renderToStaticMarkup(<Console log={log} />))
      .toContain("printed before the panel opened");
  });
});

// The cache trusts nothing it cannot still match to the text it parsed. The log
// offers no way to rewrite a line in place, so this is checked directly rather
// than through the component.
describe("Console cache", () => {
  const EMPTY = { dropped: 0, texts: [], lines: [], styles: [] };

  it("keeps the parses whose text is unchanged", () => {
    const first = update(EMPTY, ["a", "b"], 0);
    const second = update(first, ["a", "b", "c"], 0);
    expect(second.lines[0]).toBe(first.lines[0]);
    expect(second.lines[1]).toBe(first.lines[1]);
    expect(second.lines[2][0].text).toBe("c");
  });

  it("re-parses from the first line whose text no longer matches", () => {
    const first = update(EMPTY, ["a", "b"], 0);
    const second = update(first, ["a", "changed"], 0);
    expect(second.lines[0]).toBe(first.lines[0]);
    expect(second.lines[1][0].text).toBe("changed");
  });

  // A count that went backwards cannot describe a window that slid. Left
  // unclamped it is a negative index, and slice counts those from the end, so a
  // repeated line would match by luck and keep a parse made in another context.
  it("starts over when the evicted count went backwards", () => {
    const ESC = "\u001b";
    const first = update(EMPTY, [`${ESC}[34mblue`, "inherits it", "a"], 1);
    // "a" is last in the cache and first in what follows, so an unclamped
    // slice(-1) would hand it the parse made while the colour was open.
    const second = update(first, ["a", "b"], 0);
    expect(second.lines[0][0].className).toBe("");
    expect(second.lines[1][0].text).toBe("b");
  });
});
