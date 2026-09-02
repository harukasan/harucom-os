// Files panel: move files between the local machine and MEMFS.
//
// Upload is a page-wide drop target plus a file picker. Download reads the bytes
// back out of MEMFS and hands them to the browser as a Blob. MEMFS is redeployed
// from the embedded rootfs on every page load, so anything added here lives for
// the session only.
//
// Nothing needs to synchronize with the VM: DOM handlers run on the main thread
// between run loop frames, never inside mrb_run_step(), so a write can not land
// in the middle of a step.
//
// The panel is mouse driven. keyboard.js listens on window in the capture phase
// and calls preventDefault on nearly every key so the OS keeps its shortcuts,
// which also swallows Tab, the arrows and Enter before they can reach these
// controls. A <select> for the destination is still usable with the mouse where
// a text field would not be usable at all, but reaching any of this from the
// keyboard would need a guard in keyboard.js for the focused element.

import { fileExists, normalizeDestination, readFileBytes, readTree, writeFileBytes } from "./fs.js";

const DEFAULT_DESTINATION = "/data";
const READY_STATUS = "Drop files on the page to upload them.";

// Write a batch of files into `directory`. An entry only has to provide `name`
// and `arrayBuffer()`, which a DOM File satisfies and a test can fake. One bad
// entry does not stop the rest: the caller reports what landed and what did not.
// The reads stay sequential so a drop of several large samples holds one file in
// memory at a time rather than all of them.
export async function addFiles(Module, directory, files) {
  const written = [];
  const replaced = [];
  const failed = [];
  for (const file of files) {
    try {
      const path = normalizeDestination(directory, file.name);
      const existed = fileExists(Module, path);
      writeFileBytes(Module, path, new Uint8Array(await file.arrayBuffer()));
      written.push(path);
      if (existed) replaced.push(path);
    } catch (e) {
      failed.push(`${file.name}: ${e.message}`);
    }
  }
  return { written, replaced, failed };
}

// A drag carries files only when its types list says so. Without this the panel
// would light up for dragged text and, worse, the dragover preventDefault would
// suppress the browser's own drop handling across the whole page.
function isFileDrag(event) {
  return Array.from(event.dataTransfer?.types ?? []).includes("Files");
}

// Split a drop into the files to upload and the names of the entries that are
// directories. webkitGetAsEntry has to run while the handler is on the stack,
// because the items are cleared as soon as it returns.
function partitionDrop(dataTransfer) {
  const files = [];
  const folders = [];
  const items = Array.from(dataTransfer?.items ?? []);
  if (items.length === 0) return { files: Array.from(dataTransfer?.files ?? []), folders };
  for (const item of items) {
    if (item.kind !== "file") continue;
    const entry = item.webkitGetAsEntry?.();
    const file = item.getAsFile();
    if (entry?.isDirectory) folders.push(entry.name);
    else if (file) files.push(file);
  }
  return { files, folders };
}

// Wire the panel. Only listeners are installed here. The VM is untouched until
// refresh() runs, which the engine calls once the rootfs is deployed.
export function createFiles(Module, panel) {
  if (!panel) return { refresh: () => {} }; // headless (tests drive addFiles directly)

  const destination = panel.querySelector("#file-destination");
  const list = panel.querySelector("#file-list");
  const status = panel.querySelector("#file-status");
  const input = panel.querySelector("#file-input");

  function fail(what, error) {
    status.textContent = `${what}: ${error.message}`;
    console.error("files:", what, error);
  }

  // The listing is allowed to go stale (the OS writes and deletes files without
  // telling the page), so a row can name a file that is already gone.
  function download(path) {
    try {
      const bytes = readFileBytes(Module, path);
      const url = URL.createObjectURL(new Blob([bytes], { type: "application/octet-stream" }));
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = path.split("/").pop();
      // Firefox only runs the download activation for an anchor that is in the
      // document, so put it there for the click.
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      // Revoking in the same task can cancel the download that click() just
      // started, so let the current task finish first.
      setTimeout(() => URL.revokeObjectURL(url), 0);
      status.textContent = `Downloaded ${path} (${bytes.length} bytes).`;
    } catch (e) {
      fail(`Could not download ${path}`, e);
    }
  }

  function row(file) {
    const item = document.createElement("li");
    const path = document.createElement("span");
    path.className = "file-path";
    path.textContent = file.path;
    const size = document.createElement("span");
    size.className = "file-size";
    size.textContent = `${file.size} B`;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Download";
    button.addEventListener("click", () => download(file.path));
    item.append(path, size, button);
    return item;
  }

  // Rebuild both the destination picker and the list from a single walk. The OS
  // writes files too (app/edit.rb saving, mkdir), so this is also what the
  // Refresh button calls.
  function refresh() {
    const { files, directories } = readTree(Module);
    const wanted = destination.value || DEFAULT_DESTINATION;
    destination.replaceChildren(...directories.map((path) => {
      const option = document.createElement("option");
      option.value = path;
      option.textContent = path;
      return option;
    }));
    for (const path of [wanted, DEFAULT_DESTINATION, "/"]) {
      if (directories.includes(path)) { destination.value = path; break; }
    }
    list.replaceChildren(...files.map(row));
  }

  async function upload(files, folders = []) {
    const notes = folders.map((name) => `${name}: folders are not supported`);
    if (files.length === 0) {
      if (notes.length > 0) status.textContent = `Skipped: ${notes.join("; ")}`;
      return;
    }
    const directory = destination.value || "/";
    status.textContent = `Uploading ${files.length} file(s) to ${directory}...`;
    const { written, replaced, failed } = await addFiles(Module, directory, files);
    refresh();
    const parts = [];
    if (written.length > 0) {
      const suffix = replaced.length > 0 ? ` (${replaced.length} replaced)` : "";
      parts.push(`Wrote ${written.length} file(s) to ${directory}${suffix}.`);
    }
    const problems = [...failed, ...notes];
    if (problems.length > 0) parts.push(`Skipped: ${problems.join("; ")}`);
    status.textContent = parts.join(" ");
  }

  // upload() is fired from event handlers, so nothing is awaiting it. Report a
  // rejection instead of leaving the status stuck on "Uploading...".
  function startUpload(files, folders) {
    upload(files, folders).catch((e) => fail("Upload failed", e));
  }

  // Drop anywhere on the page, so the canvas is not a dead zone. Both dragover
  // and drop must preventDefault or the browser navigates to the dropped file.
  // dragenter / dragleave nest over child elements, so count them instead of
  // toggling the highlight on every boundary crossing.
  let dragDepth = 0;
  const endDrag = () => { dragDepth = 0; panel.classList.remove("dragging"); };
  document.addEventListener("dragenter", (e) => {
    if (!isFileDrag(e)) return;
    e.preventDefault();
    dragDepth++;
    panel.classList.add("dragging");
  });
  document.addEventListener("dragover", (e) => {
    if (isFileDrag(e)) e.preventDefault();
  });
  document.addEventListener("dragleave", (e) => {
    if (!isFileDrag(e)) return;
    e.preventDefault();
    if (--dragDepth <= 0) endDrag();
  });
  document.addEventListener("drop", (e) => {
    if (!isFileDrag(e)) return;
    e.preventDefault();
    endDrag();
    const { files, folders } = partitionDrop(e.dataTransfer);
    startUpload(files, folders);
  });

  panel.querySelector("#file-pick").addEventListener("click", () => input.click());
  panel.querySelector("#file-refresh").addEventListener("click", () => {
    try {
      refresh();
      status.textContent = "File list refreshed.";
    } catch (e) {
      fail("Could not list the filesystem", e);
    }
  });
  input.addEventListener("change", () => {
    const files = Array.from(input.files ?? []);
    input.value = ""; // so picking the same file again still fires change
    startUpload(files, []);
  });

  // index.html ships a neutral status, because until this point a drop would
  // still hit the browser default and navigate the page away.
  status.textContent = READY_STATUS;

  return { refresh };
}
