// stdout and stderr from the OS.
//
// The lines live in the engine's console log, not in this component, so the
// history survives being unmounted (switching tabs or dock modes tears the
// panel down) and so output from before the first mount is not lost.
//
// So does the parse. Each line is parsed once, from the state the line before it
// ended in, and the result is kept against the log rather than against this
// component: the colour a surviving line inherits was opened on a line the cap
// has since dropped, so a cache that started over on mount could not work it out
// again and the same buffer would render two ways depending on tab history.
//
// Re-parsing the joined buffer on every printed line cost 0.43 ms a line at the
// 500-line cap, which a burst of output turns into a fifth of a second taken
// from the frames that blit the screen and run the VM.
import { useEffect, useRef, useState } from "react";
import { classNameOf, parseFrom, type Span, type Style } from "./ansi";
import type { ConsoleLog } from "./engine";

interface Parsed {
  /** Lines evicted by the cap when this was last brought up to date. */
  dropped: number;
  /** The line texts these parses were made from, to detect a log that changed. */
  texts: readonly string[];
  /** Spans per line. */
  lines: Span[][];
  /** The state each line ends in, carried into the next and onto the newline. */
  styles: Style[];
}

const EMPTY: Parsed = { dropped: 0, texts: [], lines: [], styles: [] };

// One cache per log, so it outlives the component. Weak so a log that goes away
// takes its cache with it.
const caches = new WeakMap<ConsoleLog, Parsed>();

// Bring a cache up to date, parsing only the lines it does not already have.
// Exported for its own test: the log has no way to rewrite a line in place, so
// the check that a cached parse still matches its text has no route through the
// component.
export function update(cache: Parsed, lines: readonly string[], dropped: number): Parsed {
  // Clamped, because a negative index makes slice count from the end, which
  // would line a cached parse up against the wrong line rather than discard it.
  const evicted = Math.max(0, dropped - cache.dropped);
  const texts = cache.texts.slice(evicted);
  const keptLines = cache.lines.slice(evicted);
  const keptStyles = cache.styles.slice(evicted);

  // Trust nothing that does not still match the text it was parsed from. A log
  // that was cleared or rewritten in place keeps its length, so comparing
  // lengths alone would leave the old parses on screen for ever.
  let from = 0;
  while (from < keptLines.length && from < lines.length && texts[from] === lines[from]) from++;

  const parsedLines = keptLines.slice(0, from);
  const styles = keptStyles.slice(0, from);
  for (let i = from; i < lines.length; i++) {
    const { spans, style } = parseFrom(lines[i], styles[i - 1]);
    parsedLines.push(spans);
    styles.push(style);
  }
  return { dropped, texts: lines, lines: parsedLines, styles };
}

function read(log: ConsoleLog, lines: readonly string[], dropped: number): Parsed {
  const next = update(caches.get(log) ?? EMPTY, lines, dropped);
  caches.set(log, next);
  return next;
}

export function Console({ log }: { log: ConsoleLog }) {
  // Seeded rather than filled by the effect, so the first paint already has the
  // history instead of flashing an empty pane on every tab switch.
  const [parsed, setParsed] = useState<Parsed>(() => read(log, log.lines(), log.dropped()));
  const pane = useRef<HTMLPreElement>(null);

  useEffect(() => {
    setParsed(read(log, log.lines(), log.dropped())); // catch up on this mount
    // The count comes with the lines rather than from a second call, so the two
    // cannot come from either side of a write made during the dispatch.
    return log.subscribe((lines, dropped) => setParsed(read(log, lines, dropped)));
  }, [log]);

  // Follow the newest line, but only when the view is already near the bottom,
  // so reading back through the history is not yanked away. The threshold is
  // larger than a line because this runs after the new line is in the DOM: a
  // pinned view is already one line short of the bottom by the time it is asked.
  useEffect(() => {
    const el = pane.current;
    if (!el) return;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 40) el.scrollTop = el.scrollHeight;
  }, [parsed]);

  const last = parsed.lines.length - 1;
  return (
    <pre
      ref={pane}
      className="bg-base text-console font-mono text-xs leading-relaxed h-full overflow-y-auto m-0 p-2 whitespace-pre-wrap break-all"
    >
      {parsed.lines.map((spans, line) => (
        // Keyed by where the line sits in the whole output, not by its index in
        // the window. Under the cap every index holds a different line after
        // each print, so index keys would have React rewrite all five hundred.
        <span key={parsed.dropped + line}>
          {spans.map((span, index) => (
            span.className
              ? <span key={index} className={span.className}>{span.text}</span>
              : span.text
          ))}
          {/* The break carries the state the line ended in, the way it did when
              the whole buffer was one string: an open background fills it. */}
          {line < last && <span className={classNameOf(parsed.styles[line])}>{"\n"}</span>}
        </span>
      ))}
    </pre>
  );
}
