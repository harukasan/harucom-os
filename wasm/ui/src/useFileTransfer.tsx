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

// Name what was written. A count alone leaves the reader checking the listing to
// find out which file arrived, and after a drop of several that is the whole
// question. One file gets its full path; several share a directory, so the
// directory is said once and the names follow it.
function wroteMessage(written: readonly string[], replaced: readonly string[], directory: string): string {
  const replacedNote = replaced.length > 0 ? ` (${replaced.length} replaced)` : "";
  if (written.length === 1) return `Wrote ${written[0]}${replacedNote}.`;
  const names = written.map((path) => path.split("/").pop()).join(", ");
  return `Wrote ${written.length} files to ${directory}${replacedNote}: ${names}.`;
}
const READY = "Drop files on the page to upload them.";

// What the last thing to happen was, so the panel can say it in a colour rather
// than only in a sentence. A transfer either landed or it did not, and reading a
// line of grey text to find out which is exactly what a user will not do.
export type TransferOutcome = "idle" | "busy" | "ok" | "partial" | "failed";

export interface FileTransfer {
  files: FileEntry[];
  directories: string[];
  destination: string;
  setDestination(path: string): void;
  status: string;
  outcome: TransferOutcome;
  dragging: boolean;
  /** Re-read the listing. `announce` says so in the status, for the button. */
  refresh(announce?: boolean): boolean;
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
  const [outcome, setOutcome] = useState<TransferOutcome>("idle");

  // One place to set both, so a message can never be left wearing the colour of
  // whatever happened before it.
  const report = useCallback((text: string, result: TransferOutcome) => {
    setStatus(text);
    setOutcome(result);
  }, []);
  const [dragging, setDragging] = useState(false);

  // The listing goes stale on its own: the OS writes and deletes files without
  // telling the page. Refresh is how the user asks for the current truth.
  // announce is off by default because refresh also runs after an upload, where
  // it would overwrite the report of what was just written.
  const refresh = useCallback((announce = false) => {
    try {
      const tree = engine.files.tree();
      setFiles(tree.files);
      setDirectories(tree.directories);
      setDestination((current) =>
        [current, PREFERRED, "/"].find((path) => tree.directories.includes(path)) ?? "/");
      if (announce) report("File list refreshed.", "idle");
      return true;
    } catch (e) {
      report(`Could not list the filesystem: ${(e as Error).message}`, "failed");
      return false;
    }
  }, [engine, report]);

  // The provider mounts before engine.start() runs, so a listing taken now would
  // see MEMFS before the rootfs is deployed: the embedded dictionary and nothing
  // else. onReady covers both orders, firing at once when the OS is already up.
  useEffect(() => engine.onReady(() => refresh()), [engine, refresh]);

  const upload = useCallback(async (chosen: UploadCandidate[], folders: string[] = []) => {
    const notes = folders.map((name) => `${name}: folders are not supported`);
    if (chosen.length === 0) {
      if (notes.length > 0) report(`Skipped: ${notes.join("; ")}`, "failed");
      return;
    }
    report(`Uploading ${chosen.length} file(s) to ${destination}...`, "busy");
    try {
      const { written, replaced, failed } = await engine.files.add(destination, chosen);
      const listed = refresh();
      const parts = [];
      if (written.length > 0) parts.push(wroteMessage(written, replaced, destination));
      const problems = [...failed, ...notes];
      if (problems.length > 0) parts.push(`Skipped: ${problems.join("; ")}`);
      // A listing that could not be re-read is worth saying even when every file
      // landed, because what is on screen is now stale.
      if (!listed) parts.push("The listing could not be re-read.");
      report(parts.join(" "),
             problems.length > 0 || !listed ? (written.length > 0 ? "partial" : "failed") : "ok");
    } catch (e) {
      // Nothing awaits this, so a rejection would leave the status stuck on
      // "Uploading..." with no sign that anything went wrong.
      report(`Upload failed: ${(e as Error).message}`, "failed");
    }
  }, [engine, destination, refresh, report]);

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
      report(`Downloaded ${path} (${bytes.length} bytes).`, "ok");
    } catch (e) {
      report(`Could not download ${path}: ${(e as Error).message}`, "failed");
    }
  }, [engine, report]);

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
    files, directories, destination, setDestination, status, outcome, dragging, refresh, upload, download,
  };
  return <Context.Provider value={value}>{children}</Context.Provider>;
}
