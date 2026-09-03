// Moving files in and out of the browser filesystem.
//
// This lives above the panels because the drop target is the whole page: the
// canvas must not be a dead zone, and a file dropped while another tab is
// showing has to land rather than make the browser navigate away from the
// session. The Files panel only draws what this holds, so it can be unmounted
// (which it is, whenever another tab is showing) without losing any of it.
import { createContext, useCallback, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { isFileDrag, partitionDrop } from "../../js/engine/files.js";
import type { Engine, FileEntry, UploadCandidate } from "./engine";

const PREFERRED = "/data";
const READY = "Drop files on the page to upload them.";

export interface FileTransfer {
  files: FileEntry[];
  directories: string[];
  destination: string;
  setDestination(path: string): void;
  status: string;
  dragging: boolean;
  refresh(): void;
  upload(files: UploadCandidate[], folders?: string[]): Promise<void>;
  download(path: string): void;
}

const Context = createContext<FileTransfer | null>(null);

export function useFileTransfer(): FileTransfer {
  const transfer = useContext(Context);
  if (!transfer) throw new Error("useFileTransfer needs a FileTransferProvider above it");
  return transfer;
}

export function FileTransferProvider({ engine, onDrop, children }: {
  engine: Engine;
  /** Called when a drop lands, so the shell can bring the Files panel forward. */
  onDrop?: () => void;
  children: ReactNode;
}) {
  const [files, setFiles] = useState<FileEntry[]>([]);
  const [directories, setDirectories] = useState<string[]>(["/"]);
  const [destination, setDestination] = useState(PREFERRED);
  const [status, setStatus] = useState(READY);
  const [dragging, setDragging] = useState(false);

  // The listing goes stale on its own: the OS writes and deletes files without
  // telling the page. Refresh is how the user asks for the current truth.
  const refresh = useCallback(() => {
    try {
      const tree = engine.files.tree();
      setFiles(tree.files);
      setDirectories(tree.directories);
      setDestination((current) =>
        [current, PREFERRED, "/"].find((path) => tree.directories.includes(path)) ?? "/");
    } catch (e) {
      setStatus(`Could not list the filesystem: ${(e as Error).message}`);
    }
  }, [engine]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const upload = useCallback(async (chosen: UploadCandidate[], folders: string[] = []) => {
    const notes = folders.map((name) => `${name}: folders are not supported`);
    if (chosen.length === 0) {
      if (notes.length > 0) setStatus(`Skipped: ${notes.join("; ")}`);
      return;
    }
    setStatus(`Uploading ${chosen.length} file(s) to ${destination}...`);
    try {
      const { written, replaced, failed } = await engine.files.add(destination, chosen);
      refresh();
      const parts = [];
      if (written.length > 0) {
        const suffix = replaced.length > 0 ? ` (${replaced.length} replaced)` : "";
        parts.push(`Wrote ${written.length} file(s) to ${destination}${suffix}.`);
      }
      const problems = [...failed, ...notes];
      if (problems.length > 0) parts.push(`Skipped: ${problems.join("; ")}`);
      setStatus(parts.join(" "));
    } catch (e) {
      // Nothing awaits this, so a rejection would leave the status stuck on
      // "Uploading..." with no sign that anything went wrong.
      setStatus(`Upload failed: ${(e as Error).message}`);
    }
  }, [engine, destination, refresh]);

  const download = useCallback((path: string) => {
    try {
      const bytes = engine.files.read(path);
      const url = URL.createObjectURL(new Blob([bytes], { type: "application/octet-stream" }));
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = path.split("/").pop() ?? path;
      // Firefox only activates the download for an anchor that is in the
      // document, so put it there for the click.
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      // Revoking in the same task can cancel the download click() just started.
      setTimeout(() => URL.revokeObjectURL(url), 0);
      setStatus(`Downloaded ${path} (${bytes.length} bytes).`);
    } catch (e) {
      setStatus(`Could not download ${path}: ${(e as Error).message}`);
    }
  }, [engine]);

  // Both dragover and drop must preventDefault or the browser navigates to the
  // dropped file, which ends the session. dragenter and dragleave nest over
  // child elements, so count them rather than toggling on every boundary.
  useEffect(() => {
    let depth = 0;
    const onEnter = (e: DragEvent) => {
      if (!isFileDrag(e)) return;
      e.preventDefault();
      depth++;
      setDragging(true);
    };
    const onOver = (e: DragEvent) => {
      if (isFileDrag(e)) e.preventDefault();
    };
    const onLeave = (e: DragEvent) => {
      if (!isFileDrag(e)) return;
      e.preventDefault();
      if (--depth <= 0) {
        depth = 0;
        setDragging(false);
      }
    };
    const onDropped = (e: DragEvent) => {
      if (!isFileDrag(e)) return;
      e.preventDefault();
      depth = 0;
      setDragging(false);
      const { files: dropped, folders } = partitionDrop(e.dataTransfer);
      onDrop?.();
      void upload(dropped, folders);
    };
    document.addEventListener("dragenter", onEnter);
    document.addEventListener("dragover", onOver);
    document.addEventListener("dragleave", onLeave);
    document.addEventListener("drop", onDropped);
    return () => {
      document.removeEventListener("dragenter", onEnter);
      document.removeEventListener("dragover", onOver);
      document.removeEventListener("dragleave", onLeave);
      document.removeEventListener("drop", onDropped);
    };
  }, [upload, onDrop]);

  const value: FileTransfer = {
    files, directories, destination, setDestination, status, dragging, refresh, upload, download,
  };
  return <Context.Provider value={value}>{children}</Context.Provider>;
}
