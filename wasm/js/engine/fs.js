// MEMFS helpers: the DOM-free half of the browser filesystem.
//
// MEMFS is the whole filesystem in the browser build (the board mounts LittleFS
// through VFS instead), and harucom_init deploys the embedded rootfs into it on
// every page load. Everything here talks to the emscripten FS API and nothing
// else, so it can be driven from a test against a plain Module. The DOM glue
// that uses it lives in files.js, mirroring the hid.js / keyboard.js split.

// Paths left out of the listings. /dev is an emscripten device mount, not part
// of the board's filesystem, and reading /dev/urandom would never end.
const SKIP_DEFAULT = ["/dev"];

// Make the wasm filesystem root match the board.
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

// Join a destination directory and a file name into an absolute MEMFS path.
// A name that arrives with a dropped file is not trusted, so this throws rather
// than guessing: a separator or a .. segment would otherwise let an upload land
// outside the chosen directory.
export function normalizeDestination(directory, name) {
  if (typeof directory !== "string" || !directory.startsWith("/")) {
    throw new Error(`destination must be an absolute path: ${directory}`);
  }
  const segments = directory.split("/").filter((segment) => segment !== "");
  if (segments.some((segment) => segment === "." || segment === "..")) {
    throw new Error(`destination must not contain . or ..: ${directory}`);
  }
  if (typeof name !== "string" || name === "") {
    throw new Error("file name is empty");
  }
  if (name.includes("/") || name.includes("\\")) {
    throw new Error(`file name must not contain a path separator: ${name}`);
  }
  if (name === "." || name === "..") {
    throw new Error(`invalid file name: ${name}`);
  }
  return "/" + [...segments, name].join("/");
}

// Create every parent directory of an absolute path. A directory that already
// exists raises EEXIST, which is the normal case here. Any other failure is left
// for the write itself to report, where the message names the file.
function ensureDirectories(Module, path) {
  const segments = path.split("/").filter((segment) => segment !== "");
  segments.pop(); // the file name itself
  let current = "";
  for (const segment of segments) {
    current += "/" + segment;
    try { Module.FS.mkdir(current); } catch { /* already there */ }
  }
}

export function fileExists(Module, path) {
  try {
    return Module.FS.isFile(Module.FS.stat(path).mode);
  } catch {
    return false;
  }
}

// Write raw bytes, creating the parent directories first. An existing file is
// replaced.
export function writeFileBytes(Module, path, bytes) {
  ensureDirectories(Module, path);
  Module.FS.writeFile(path, bytes);
}

// Read a file back as bytes. FS.readFile defaults to binary, so this is a
// Uint8Array and survives non-UTF-8 content (samples, bitmaps).
export function readFileBytes(Module, path) {
  return Module.FS.readFile(path);
}

function walk(Module, path, skip, files, directories) {
  for (const name of Module.FS.readdir(path)) {
    if (name === "." || name === "..") continue;
    const child = path === "/" ? "/" + name : path + "/" + name;
    if (skip.includes(child)) continue;
    let stat;
    try { stat = Module.FS.stat(child); } catch { continue; }
    if (Module.FS.isDir(stat.mode)) {
      directories.push(child);
      walk(Module, child, skip, files, directories);
    } else if (Module.FS.isFile(stat.mode)) {
      files.push({ path: child, size: stat.size });
    }
  }
}

// Walk the whole tree once and return both halves sorted by path: files as
// { path, size } and directories as paths (always including the root). One walk
// serves both the file list and the destination picker.
export function readTree(Module, { skip = SKIP_DEFAULT } = {}) {
  const files = [];
  const directories = ["/"];
  walk(Module, "/", skip, files, directories);
  const byPath = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  files.sort((a, b) => byPath(a.path, b.path));
  directories.sort(byPath);
  return { files, directories };
}
