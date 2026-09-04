// Turn the SGR escapes the OS prints into styled runs.
//
// The console mirrors what a terminal would show, so `ls` marks its directories
// and an error arrives in red, the same as on the board's own screen. Only SGR
// (`ESC [ ... m`) is handled: that is what rootfs/lib/console.rb emits. Any other
// escape is dropped rather than printed, because showing the raw bytes is worse
// than showing nothing.
//
// A colour opened on one line and closed on the next has to end where it was
// meant to, so parseFrom takes the state the previous run left and returns the
// state this one ends in. That is what lets the console parse a line at a time
// and keep the result, instead of re-reading the whole buffer on every print.

export interface Span {
  text: string;
  /** Tailwind classes for this run, empty for the default style. */
  className: string;
}

// Literal class names, because Tailwind scans sources for them: a name built at
// runtime would never have its utility generated.
const FOREGROUND: Record<number, string> = {
  30: "text-ansi-black", 31: "text-ansi-red", 32: "text-ansi-green", 33: "text-ansi-yellow",
  34: "text-ansi-blue", 35: "text-ansi-magenta", 36: "text-ansi-cyan", 37: "text-ansi-white",
  90: "text-ansi-bright-black", 91: "text-ansi-bright-red", 92: "text-ansi-bright-green",
  93: "text-ansi-bright-yellow", 94: "text-ansi-bright-blue", 95: "text-ansi-bright-magenta",
  96: "text-ansi-bright-cyan", 97: "text-ansi-bright-white",
};

const BACKGROUND: Record<number, string> = {
  40: "bg-ansi-black", 41: "bg-ansi-red", 42: "bg-ansi-green", 43: "bg-ansi-yellow",
  44: "bg-ansi-blue", 45: "bg-ansi-magenta", 46: "bg-ansi-cyan", 47: "bg-ansi-white",
};

interface Style {
  foreground: string;
  background: string;
  bold: boolean;
}

const PLAIN: Style = { foreground: "", background: "", bold: false };

function apply(style: Style, codes: number[]): Style {
  let next = style;
  // An empty parameter list means SGR 0, which is how a bare reset is written.
  for (const code of codes.length > 0 ? codes : [0]) {
    if (code === 0) next = PLAIN;
    else if (code === 1) next = { ...next, bold: true };
    else if (code === 22) next = { ...next, bold: false };
    else if (code === 39) next = { ...next, foreground: "" };
    else if (code === 49) next = { ...next, background: "" };
    else if (FOREGROUND[code]) next = { ...next, foreground: FOREGROUND[code] };
    else if (BACKGROUND[code]) next = { ...next, background: BACKGROUND[code] };
    // Anything else (underline, 256-colour, cursor moves) is ignored rather
    // than guessed at.
  }
  return next;
}

// Exported so the console can style the newline between two lines with the
// state the first one ended in, which is what it carried when the whole buffer
// was parsed as one string.
export function classNameOf(style: Style): string {
  return [style.foreground, style.background, style.bold ? "font-bold" : ""]
    .filter(Boolean).join(" ");
}

// ESC [ params letter. The ESC has to be part of the pattern: a bare bracket is
// ordinary text, and the keyboard readout prints plenty of them. The final byte
// is 0x40 to 0x7e, so this also matches, and therefore removes, the escapes
// that are not SGR.
const ESCAPE = /\u001b\[([0-9;]*)([@-~])/g;

/** The escape state a run of text ends in, to carry into the next one. */
export type { Style };

// Parse one run, starting from the state the previous run left. PLAIN is not
// exported: it is the object apply() assigns for a reset, so handing it out
// would let a caller's edit change what every later reset means.
export function parseFrom(text: string, entering: Style = PLAIN): { spans: Span[]; style: Style } {
  const spans: Span[] = [];
  let style = entering;
  let at = 0;

  const push = (chunk: string) => {
    if (!chunk) return;
    const className = classNameOf(style);
    const last = spans[spans.length - 1];
    // Merge with the run before it when the style did not change, so a reset
    // followed by the same colour does not become two elements.
    if (last && last.className === className) last.text += chunk;
    else spans.push({ text: chunk, className });
  };

  ESCAPE.lastIndex = 0;
  for (let match = ESCAPE.exec(text); match; match = ESCAPE.exec(text)) {
    push(text.slice(at, match.index));
    at = match.index + match[0].length;
    if (match[2] !== "m") continue; // not SGR: swallowed, not printed
    style = apply(style, match[1].split(";").filter((part) => part !== "").map(Number));
  }
  push(text.slice(at));
  return { spans, style };
}

// The whole text at once. No production code calls this: it is the reference
// definition the line-at-a-time parse is tested against, so a line-by-line run
// and a single pass over the same text have to agree.
export function parseAnsi(text: string): Span[] {
  return parseFrom(text).spans;
}
