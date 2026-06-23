// MEMFS cleanup: make the wasm filesystem root match the board.
//
// The emscripten runtime creates directories the board's LittleFS root does not
// have (/home, /tmp, /proc). Remove them so `ls /` in the browser looks like the
// board. /dev is deliberately kept: the posix RNG / mbedtls ports read
// /dev/urandom, whereas the board uses a hardware RNG and has no /dev.
//
// Done in JS (not C) because /proc/self/fd is an emscripten mount, and only the
// FS API can unmount it (POSIX rmdir cannot remove a mount point). Requires `FS`
// in the module's EXPORTED_RUNTIME_METHODS. Call once after the module is created.

export function pruneRuntimeDirs(Module) {
  const FS = Module.FS;

  const rmrf = (path) => {
    let st;
    try { st = FS.stat(path); } catch { return; } // already gone
    if (FS.isDir(st.mode)) {
      for (const name of FS.readdir(path)) {
        if (name === "." || name === "..") continue;
        rmrf(path + "/" + name);
      }
      try { FS.rmdir(path); } catch { /* mount point or busy; leave it */ }
    } else {
      try { FS.unlink(path); } catch { /* ignore */ }
    }
  };

  rmrf("/home");
  rmrf("/tmp");
  // /proc/self/fd is an emscripten procfs mount whose fd entries cannot be
  // unlinked (so rmrf's recurse-then-rmdir leaves it). FS.rmdir removes the
  // procfs dirs directly even while non-empty, so just rmdir the tree bottom-up.
  for (const path of ["/proc/self/fd", "/proc/self", "/proc"]) {
    try { FS.rmdir(path); } catch { /* ignore */ }
  }
}
