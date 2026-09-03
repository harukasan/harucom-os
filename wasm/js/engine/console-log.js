// The stdout/stderr buffer behind the console panel.
//
// It is created before the emscripten Module, because print handlers can only be
// installed at construction time and the OS prints during harucom_init. It
// outlives every panel, so switching tabs or dock modes (which unmounts the
// console) does not lose the history the user has already seen.
//
// The buffer is capped: the OS can print without bound, and the panel renders
// the whole of it.
export function createConsoleLog({ limit = 500 } = {}) {
  let lines = [];
  let dropped = 0; // lines evicted by the cap, so a reader can align its own work
  const subscribers = [];

  return {
    // Wire this to Module.print and Module.printErr. Emscripten calls it once
    // per line, without the newline.
    write(line) {
      // concat, not push: React compares by identity, so a mutated array would
      // look unchanged and the console would stop updating.
      const next = lines.concat(line);
      if (next.length > limit) {
        dropped += next.length - limit;
        lines = next.slice(next.length - limit);
      } else {
        lines = next;
      }
      // Both, together: a reader that took the lines here and asked for the
      // count separately could get one from before a nested write and the other
      // from after, and line its cache up against the wrong line.
      for (const callback of subscribers.slice()) callback(lines, dropped);
    },

    // The lines so far, for a panel that mounts after output has started.
    lines() {
      return lines;
    },

    // How many lines the cap has evicted. With this a reader can tell an append
    // from a window that has slid, and so keep the work it has already done on
    // the lines it still holds.
    dropped() {
      return dropped;
    },

    subscribe(callback) {
      subscribers.push(callback);
      return () => {
        const i = subscribers.indexOf(callback);
        if (i >= 0) subscribers.splice(i, 1);
      };
    },
  };
}
