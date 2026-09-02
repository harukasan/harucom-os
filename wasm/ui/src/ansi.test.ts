import { describe, it, expect } from "vitest";
import { parseAnsi } from "./ansi";

const ESC = "\u001b"; // written as an escape so the source stays readable

describe("parseAnsi", () => {
  it("leaves plain text as one run", () => {
    expect(parseAnsi("hello")).toEqual([{ text: "hello", className: "" }]);
  });

  it("colours the run between a colour and its reset", () => {
    expect(parseAnsi(`a${ESC}[34mapp${ESC}[0mb`)).toEqual([
      { text: "a", className: "" },
      { text: "app", className: "text-ansi-blue" },
      { text: "b", className: "" },
    ]);
  });

  it("keeps a colour running to the end when nothing resets it", () => {
    expect(parseAnsi(`${ESC}[31mboom`)).toEqual([{ text: "boom", className: "text-ansi-red" }]);
  });

  // A colour opened on one line and closed on the next is why the whole text is
  // parsed at once instead of line by line.
  it("carries a style across a newline", () => {
    expect(parseAnsi(`${ESC}[32mone\ntwo${ESC}[0m`)).toEqual([
      { text: "one\ntwo", className: "text-ansi-green" },
    ]);
  });

  it("combines a foreground, a background and bold", () => {
    const [span] = parseAnsi(`${ESC}[1;33;44mx`);
    expect(span.className.split(" ").sort()).toEqual(
      ["bg-ansi-blue", "font-bold", "text-ansi-yellow"]);
  });

  it("resets only what the code names", () => {
    expect(parseAnsi(`${ESC}[31;44mx${ESC}[39my`)).toEqual([
      { text: "x", className: "text-ansi-red bg-ansi-blue" },
      { text: "y", className: "bg-ansi-blue" },
    ]);
  });

  it("treats a bare reset as SGR 0", () => {
    expect(parseAnsi(`${ESC}[31mx${ESC}[my`)).toEqual([
      { text: "x", className: "text-ansi-red" },
      { text: "y", className: "" },
    ]);
  });

  it("merges neighbouring runs that end up styled the same", () => {
    expect(parseAnsi(`${ESC}[34ma${ESC}[0m${ESC}[34mb`)).toEqual([
      { text: "ab", className: "text-ansi-blue" },
    ]);
  });

  // A bracket is ordinary text. The keyboard readout prints held=[0x4], and
  // matching that as an escape would eat the rest of the line.
  it("leaves a bare bracket alone", () => {
    expect(parseAnsi("held=[0x4] mod=0x2")).toEqual([
      { text: "held=[0x4] mod=0x2", className: "" },
    ]);
  });

  // Showing the raw bytes of an escape nobody renders is worse than showing
  // nothing, and a cursor move would otherwise print as garbage mid-line.
  it("swallows an escape that is not SGR", () => {
    expect(parseAnsi(`a${ESC}[2Jb`)).toEqual([{ text: "ab", className: "" }]);
  });

  it("ignores a code it has no styling for", () => {
    expect(parseAnsi(`${ESC}[4munderlined`)).toEqual([
      { text: "underlined", className: "" },
    ]);
  });
});
