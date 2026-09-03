// Moving files between the local machine and MEMFS.
//
// MEMFS is redeployed from the embedded rootfs on every page load, so anything
// written here lives for the session only.
//
// Nothing needs to synchronize with the VM: DOM handlers run on the main thread
// between run loop frames, never inside mrb_run_step(), so a write cannot land
// in the middle of a step.
//
// This module is DOM free apart from reading a DataTransfer, which is what the
// files panel hands it. The panel draws the list and the status.

import { fileExists, normalizeDestination, writeFileBytes } from "./fs.js";

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
export function isFileDrag(event) {
  return Array.from(event.dataTransfer?.types ?? []).includes("Files");
}

// Split a drop into the files to upload and the names of the entries that are
// directories. webkitGetAsEntry has to run while the handler is on the stack,
// because the items are cleared as soon as it returns.
export function partitionDrop(dataTransfer) {
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
