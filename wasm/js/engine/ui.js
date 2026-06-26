// Funicular UI loader: write the UI Ruby sources into MEMFS under /_web and start
// them on the VM.
//
// The UI lives outside the OS rootfs in a clearly-named, OS-visible directory
// (/_web, the web-tooling underscore convention). It is loaded with require, so
// the sources stay on MEMFS and editing them is a restage + reload (no emcc
// rebuild). `files` maps a path relative to /_web to its source string; the
// browser fetches them, the node harness reads them from disk. `panels` is the
// list of panel module basenames (lib/*_panel.rb without the extension), which
// shell.rb requires so each panel self-registers a tab.

function mkdirp(FS, dir) {
  let cur = "";
  for (const part of dir.split("/")) {
    if (!part) continue;
    cur += "/" + part;
    try { FS.mkdir(cur); } catch { /* already exists */ }
  }
}

// Write the UI sources into /_web. Does not start anything (call startUI next),
// so a reload can rewrite the files and restart cleanly.
export function installUI(Module, files) {
  const FS = Module.FS;
  for (const [rel, src] of Object.entries(files)) {
    const full = "/_web/" + rel;
    mkdirp(FS, full.slice(0, full.lastIndexOf("/")));
    FS.writeFile(full, src);
  }
}

// Load the shell entry and boot the App with the discovered panels (also the
// hot-reload entry: rewrite files via installUI, call again). /_web/lib goes on
// the load path so require resolves there. Returns the harucom_run_ruby result
// (0 on success).
export function startUI(Module, { panels = [] } = {}) {
  const list = panels.map((name) => JSON.stringify(name)).join(", ");
  const code =
    '$LOAD_PATH.unshift "/_web/lib" unless $LOAD_PATH.include?("/_web/lib")\n' +
    'load "/_web/lib/shell.rb"\n' +
    "Harucom::UI.boot([" + list + "])\n";
  return Module.ccall("harucom_run_ruby", "number", ["string"], [code]);
}
