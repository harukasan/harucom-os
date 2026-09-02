// stdout and stderr from the OS.
//
// The lines live in the engine's console log, not in this component, so the
// history survives being unmounted (switching tabs or dock modes tears the
// panel down) and so output from before the first mount is not lost.
import { useEffect, useMemo, useRef, useState } from "react";
import { parseAnsi } from "./ansi";
import type { ConsoleLog } from "./engine";

export function Console({ log }: { log: ConsoleLog }) {
  const [lines, setLines] = useState<readonly string[]>(() => log.lines());
  const pane = useRef<HTMLPreElement>(null);

  useEffect(() => {
    setLines(log.lines()); // catch up on anything printed before this mount
    return log.subscribe(setLines);
  }, [log]);

  // Follow the newest line, but only when the view is already near the bottom,
  // so reading back through the history is not yanked away. The threshold is
  // larger than a line because this runs after the new line is in the DOM: a
  // pinned view is already one line short of the bottom by the time it is asked.
  useEffect(() => {
    const el = pane.current;
    if (!el) return;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 40) el.scrollTop = el.scrollHeight;
  }, [lines]);

  // Parsed once per batch of lines rather than per render, since the pane also
  // re-renders when it is resized or re-docked.
  const spans = useMemo(() => parseAnsi(lines.join("\n")), [lines]);

  return (
    <pre
      ref={pane}
      className="bg-base text-console font-mono text-xs leading-relaxed h-full overflow-y-auto m-0 p-2 whitespace-pre-wrap break-all"
    >
      {spans.map((span, index) => (
        span.className
          ? <span key={index} className={span.className}>{span.text}</span>
          : span.text
      ))}
    </pre>
  );
}
