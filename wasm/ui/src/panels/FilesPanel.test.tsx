import { describe, it, expect, vi } from "vitest";
import { render, act, screen } from "@testing-library/react";
import { filesPanel } from "./FilesPanel";
import { FileTransferProvider } from "../useFileTransfer";
import { stubEngine } from "../test-engine";
import { createConsoleLog } from "../engine";
import type { FileTree, Files } from "../engine";

const Panel = filesPanel.Component;

function stubFiles(tree: FileTree, overrides: Partial<Files> = {}): Files {
  return {
    add: vi.fn(async () => ({ written: [], replaced: [], failed: [] })),
    tree: () => tree,
    read: () => new Uint8Array(new ArrayBuffer(0)),
    ...overrides,
  };
}

function setup(files: Files, options?: { started?: boolean }) {
  const log = createConsoleLog();
  const engine = stubEngine(log, files, options);
  return {
    engine,
    ...render(
      <FileTransferProvider engine={engine}>
        <Panel engine={engine} log={log} />
      </FileTransferProvider>,
    ),
  };
}

const TREE: FileTree = {
  files: [{ path: "/system.rb", size: 2683 }, { path: "/data/kick.wav", size: 12 }],
  directories: ["/", "/app", "/data"],
};

describe("FilesPanel", () => {
  it("lists what the filesystem holds", () => {
    setup(stubFiles(TREE));
    expect(screen.getByText("/system.rb")).toBeTruthy();
    expect(screen.getByText("2683 B")).toBeTruthy();
  });

  // /data is where a sample or a script is meant to land, so it is the default
  // when it exists rather than the root, where a stray file would clutter the
  // listing the OS itself boots from.
  it("offers the directories and starts at /data", () => {
    setup(stubFiles(TREE));
    const picker = screen.getByLabelText("Upload to") as HTMLSelectElement;
    expect(picker.value).toBe("/data");
    expect([...picker.options].map((o) => o.value)).toEqual(["/", "/app", "/data"]);
  });

  it("falls back to the root when there is no /data", () => {
    setup(stubFiles({ files: [], directories: ["/", "/app"] }));
    expect((screen.getByLabelText("Upload to") as HTMLSelectElement).value).toBe("/");
  });

  it("uploads the chosen files to the chosen directory", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: ["/data/a.txt"], replaced: [], failed: [] })),
    });
    setup(files);
    const picker = screen.getByLabelText("Files to upload") as HTMLInputElement;
    const file = new File(["hi"], "a.txt");
    Object.defineProperty(picker, "files", { value: [file] });
    await act(async () => {
      picker.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    expect(files.add).toHaveBeenCalledWith("/data", [file]);
    expect(screen.getByText(/Wrote 1 file\(s\) to \/data/)).toBeTruthy();
  });

  it("says which uploads were rejected", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: [], replaced: [], failed: ["../escape.txt: name carries a separator"] })),
    });
    setup(files);
    const picker = screen.getByLabelText("Files to upload") as HTMLInputElement;
    Object.defineProperty(picker, "files", { value: [new File(["x"], "../escape.txt")] });
    await act(async () => {
      picker.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    expect(screen.getByText(/Skipped:.*escape\.txt/)).toBeTruthy();
  });

  // The listing goes stale on its own: the OS writes and deletes files without
  // telling the page, so a row can name a file that is already gone.
  it("reports a download of a file that is no longer there", () => {
    setup(stubFiles(TREE, {
      read: () => { throw new Error("no such file"); },
    }));
    act(() => {
      screen.getAllByRole("button", { name: "Download" })[0].click();
    });
    expect(screen.getByText(/Could not download \/system\.rb/)).toBeTruthy();
  });

  // Nothing awaits the upload, so a rejection would leave the status stuck on
  // "Uploading..." with no sign that anything went wrong.
  it("reports an upload that rejects rather than hanging on Uploading", async () => {
    const files = stubFiles(TREE, { add: vi.fn(async () => { throw new Error("out of memory"); }) });
    setup(files);
    const picker = screen.getByLabelText("Files to upload") as HTMLInputElement;
    Object.defineProperty(picker, "files", { value: [new File(["x"], "a.txt")] });
    await act(async () => {
      picker.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    expect(screen.getByText(/Upload failed: out of memory/)).toBeTruthy();
  });

  // The panel mounts before engine.start() deploys the rootfs, so a listing
  // taken then sees only the file emscripten embedded. Without the second read
  // the Files panel shows /dict.bin and nothing else for the whole session.
  it("lists the rootfs once the OS says it is there", () => {
    let tree: FileTree = { files: [{ path: "/dict.bin", size: 4 }], directories: ["/"] };
    const { engine } = setup(stubFiles(tree, { tree: () => tree }), { started: false });
    expect(screen.queryByText("/system.rb")).toBeNull();
    tree = TREE;
    act(() => engine.ready());
    expect(screen.getByText("/system.rb")).toBeTruthy();
  });

  // Pressing a button that appears to do nothing reads as broken, and the
  // listing usually looks identical afterwards.
  it("says so when the listing is re-read by hand", () => {
    setup(stubFiles(TREE));
    act(() => {
      screen.getByRole("button", { name: "Refresh" }).click();
    });
    expect(screen.getByText("File list refreshed.")).toBeTruthy();
  });

  // An upload reports what it wrote. Re-reading the listing afterwards must not
  // replace that with a line about the listing.
  it("keeps the upload report when it re-reads the listing itself", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: ["/data/a.txt"], replaced: [], failed: [] })),
    });
    setup(files);
    const picker = screen.getByLabelText("Files to upload") as HTMLInputElement;
    Object.defineProperty(picker, "files", { value: [new File(["hi"], "a.txt")] });
    await act(async () => {
      picker.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    expect(screen.getByText(/Wrote 1 file/)).toBeTruthy();
  });

  it("says why the listing could not be read", () => {
    setup(stubFiles(TREE, { tree: () => { throw new Error("FS is gone"); } }));
    expect(screen.getByText(/Could not list the filesystem: FS is gone/)).toBeTruthy();
  });
});
