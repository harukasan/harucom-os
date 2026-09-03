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

const status = () => screen.getByRole("status");

async function upload(file: File) {
  const picker = screen.getByLabelText("Files to upload") as HTMLInputElement;
  Object.defineProperty(picker, "files", { value: [file], configurable: true });
  await act(async () => {
    picker.dispatchEvent(new window.Event("change", { bubbles: true }));
  });
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
    // The path, not a count: after a drop the question is which file arrived.
    expect(screen.getByText("Wrote /data/a.txt.")).toBeTruthy();
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

  // An upload reports what it wrote, and re-reads the listing afterwards. When
  // that read fails the report has to survive and say so, rather than being
  // replaced by the listing error or hiding it.
  it("keeps the upload report when the listing after it cannot be read", async () => {
    let reads = 0;
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: ["/data/a.txt"], replaced: [], failed: [] })),
      tree: () => {
        if (++reads > 1) throw new Error("FS is gone");
        return TREE;
      },
    });
    setup(files);
    await upload(new File(["hi"], "a.txt"));
    expect(status().textContent).toMatch(/Wrote \/data\/a\.txt\./);
    expect(status().textContent).toMatch(/could not be re-read/);
    expect(status().className).toContain("text-ansi-yellow");
  });

  // Several files share a directory, so it is said once and the names follow,
  // rather than repeating the path on every one.
  it("names every file when a batch lands", async () => {
    const written = ["/data/kick.wav", "/data/snare.wav", "/data/hat.wav"];
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written, replaced: [], failed: [] })),
    });
    setup(files);
    await upload(new File(["x"], "kick.wav"));
    expect(status().textContent).toBe("Wrote 3 files to /data: kick.wav, snare.wav, hat.wav.");
  });

  it("says how many of them replaced something", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: ["/data/a.txt"], replaced: ["/data/a.txt"], failed: [] })),
    });
    setup(files);
    await upload(new File(["x"], "a.txt"));
    expect(status().textContent).toBe("Wrote /data/a.txt (1 replaced).");
  });

  // Colour is the part a user actually reads. A message wearing the wrong one is
  // worse than no colour at all.
  it("says how it went in colour", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: ["/data/a.txt"], replaced: [], failed: [] })),
    });
    setup(files);
    expect(status().className).toContain("text-fg-dim"); // nothing has happened yet
    await upload(new File(["hi"], "a.txt"));
    expect(status().className).toContain("text-ansi-green");
  });

  it("marks a refused upload in red", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: [], replaced: [], failed: ["../escape.txt: name carries a separator"] })),
    });
    setup(files);
    await upload(new File(["x"], "../escape.txt"));
    expect(status().className).toContain("text-ansi-red");
  });

  it("marks a partly written batch in yellow", async () => {
    const files = stubFiles(TREE, {
      add: vi.fn(async () => ({ written: ["/data/a.txt"], replaced: [], failed: ["b.txt: no space"] })),
    });
    setup(files);
    await upload(new File(["x"], "a.txt"));
    expect(status().className).toContain("text-ansi-yellow");
  });

  it("says why the listing could not be read", () => {
    setup(stubFiles(TREE, { tree: () => { throw new Error("FS is gone"); } }));
    expect(screen.getByText(/Could not list the filesystem: FS is gone/)).toBeTruthy();
  });

  // A select whose value has no matching option renders blank, so the control
  // would show nothing while uploads still went to the directory it had stopped
  // naming.
  it("still names the destination when the listing could not be read", () => {
    setup(stubFiles(TREE, { tree: () => { throw new Error("FS is gone"); } }));
    const picker = screen.getByLabelText("Upload to") as HTMLSelectElement;
    expect(picker.value).toBe("/data");
    expect([...picker.options].map((o) => o.value)).toContain("/data");
  });
});
