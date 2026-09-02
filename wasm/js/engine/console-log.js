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
  const subscribers = [];

  return {
    // Wire this to Module.print and Module.printErr. Emscripten calls it once
    // per line, without the newline.
    write(line) {
      // concat, not push: React compares by identity, so a mutated array would
      // look unchanged and the console would stop updating.
      const next = lines.concat(line);
      lines = next.length > limit ? next.slice(next.length - limit) : next;
      for (const callback of subscribers.slice()) callback(lines);
    },

    // The lines so far, for a panel that mounts after output has started.
    lines() {
      return lines;
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
