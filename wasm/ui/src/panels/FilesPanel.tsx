// Move files between the local machine and the browser's filesystem.
//
// MEMFS is rebuilt from the embedded rootfs on every page load, so an uploaded
// file lasts for the session. That is the point: it is how a sample or a script
// gets in front of the OS without rebuilding the rootfs into the firmware.
//
// The state lives above the panels (useFileTransfer), because the drop target is
// the whole page and this panel is unmounted whenever another tab is showing.
//
// The panel is mouse driven. keyboard.js listens on window in the capture phase
// and calls preventDefault on nearly every key so the OS keeps its shortcuts,
// which also swallows Tab, the arrows and Enter before they could reach these
// controls.
import { useRef } from "react";
import { useFileTransfer } from "../useFileTransfer";
import type { PanelDefinition } from "./types";

const BUTTON =
  "px-2 py-1 rounded bg-pad text-fg text-xs border border-border " +
  "hover:bg-border-hover cursor-pointer";

function FilesPanel() {
  const transfer = useFileTransfer();
  const picker = useRef<HTMLInputElement>(null);

  return (
    <div className={`h-full flex flex-col text-xs ${transfer.dragging ? "bg-border-hover" : ""}`}>
      <div className="flex items-center gap-2 p-2 border-b border-border">
        <label htmlFor="file-destination" className="text-fg-dim">Upload to</label>
        <select
          id="file-destination"
          className="bg-pad text-fg border border-border rounded px-1 py-1"
          value={transfer.destination}
          onChange={(e) => transfer.setDestination(e.target.value)}
        >
          {transfer.directories.map((path) => <option key={path} value={path}>{path}</option>)}
        </select>
        <button type="button" className={BUTTON} onClick={() => picker.current?.click()}>
          Choose files
        </button>
        <button type="button" className={BUTTON} onClick={transfer.refresh}>
          Refresh
        </button>
        <input
          ref={picker}
          type="file"
          multiple
          hidden
          aria-label="Files to upload"
          onChange={(e) => {
            const chosen = Array.from(e.target.files ?? []);
            e.target.value = ""; // so picking the same file again still fires change
            void transfer.upload(chosen);
          }}
        />
      </div>
      <p className="px-2 py-1 text-fg-dim m-0">{transfer.status}</p>
      <ul className="flex-1 overflow-auto m-0 p-0 list-none">
        {transfer.files.map((file) => (
          <li key={file.path} className="flex items-center gap-2 px-2 py-0.5 font-mono">
            <span className="flex-1 truncate">{file.path}</span>
            <span className="text-fg-dim">{file.size} B</span>
            <button type="button" className={BUTTON} onClick={() => transfer.download(file.path)}>
              Download
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

export const filesPanel: PanelDefinition = {
  slug: "files",
  title: "Files",
  Component: FilesPanel,
};
