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
// The destination is a <select>, not a text input, on purpose. keyboard.js
// listens on window in the capture phase and preventDefault()s nearly every key
// so the OS keeps its shortcuts, which would swallow anything typed into a text
// field. A text input here would first need a guard in keyboard.js that lets
// keys through while document.activeElement is editable.

import { fileExists, normalizeDestination, readFileBytes, readTree, writeFileBytes } from "./fs.js";

const DEFAULT_DESTINATION = "/data";

// Write a batch of files into `directory`. An entry only has to provide `name`
// and `arrayBuffer()`, which a DOM File satisfies and a test can fake. One bad
// entry does not stop the rest: the caller reports what landed and what did not.
export async function addFiles(Module, directory, files) {
  const written = [];
  const replaced = [];
  const failed = [];
  for (const file of files) {
    try {
      const path = normalizeDestination(directory, file.name);
      if (fileExists(Module, path)) replaced.push(path);
      writeFileBytes(Module, path, new Uint8Array(await file.arrayBuffer()));
      written.push(path);
    } catch (e) {
      failed.push(`${file.name}: ${e.message}`);
    }
  }
  return { written, replaced, failed };
}

// Wire the panel. Only listeners are installed here. The VM is untouched until
// refresh() runs, which the engine calls once the rootfs is deployed.
export function createFiles(Module, panel) {
  if (!panel) return { refresh: () => {} }; // headless (tests drive addFiles directly)

  const destination = panel.querySelector("#file-destination");
  const list = panel.querySelector("#file-list");
  const status = panel.querySelector("#file-status");
  const input = panel.querySelector("#file-input");

  function download(path) {
    const bytes = readFileBytes(Module, path);
    const url = URL.createObjectURL(new Blob([bytes], { type: "application/octet-stream" }));
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = path.split("/").pop();
    anchor.click();
    // Revoking in the same task can cancel the download that click() just
    // started, so let the current task finish first.
    setTimeout(() => URL.revokeObjectURL(url), 0);
    status.textContent = `Downloaded ${path} (${bytes.length} bytes).`;
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

  async function upload(files) {
    if (files.length === 0) return;
    const directory = destination.value || "/";
    status.textContent = `Uploading ${files.length} file(s) to ${directory}...`;
    const { written, replaced, failed } = await addFiles(Module, directory, files);
    refresh();
    const parts = [];
    if (written.length > 0) {
      const suffix = replaced.length > 0 ? ` (${replaced.length} replaced)` : "";
      parts.push(`Wrote ${written.length} file(s) to ${directory}${suffix}.`);
    }
    if (failed.length > 0) parts.push(`Failed: ${failed.join("; ")}`);
    status.textContent = parts.join(" ");
  }

  // Drop anywhere on the page, so the canvas is not a dead zone. Both dragover
  // and drop must preventDefault or the browser navigates to the dropped file.
  // dragenter / dragleave nest over child elements, so count them instead of
  // toggling the highlight on every boundary crossing.
  let dragDepth = 0;
  const endDrag = () => { dragDepth = 0; panel.classList.remove("dragging"); };
  document.addEventListener("dragenter", (e) => {
    e.preventDefault();
    dragDepth++;
    panel.classList.add("dragging");
  });
  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("dragleave", (e) => {
    e.preventDefault();
    if (--dragDepth <= 0) endDrag();
  });
  document.addEventListener("drop", (e) => {
    e.preventDefault();
    endDrag();
    upload(Array.from(e.dataTransfer?.files ?? []));
  });

  panel.querySelector("#file-pick").addEventListener("click", () => input.click());
  panel.querySelector("#file-refresh").addEventListener("click", () => {
    refresh();
    status.textContent = "File list refreshed.";
  });
  input.addEventListener("change", () => {
    const files = Array.from(input.files ?? []);
    input.value = ""; // so picking the same file again still fires change
    upload(files);
  });

  return { refresh };
}
