// File transfer gate: the browser can put a file into MEMFS where the OS reads
// it, and can read one back out byte for byte. The panel markup in index.html
// and the ids files.js looks up are checked against each other by building the
// panel from that same markup.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const nodeFs = require("node:fs");
const path = require("node:path");
const { boot } = require("./harness.cjs");

const INDEX_HTML = path.join(__dirname, "..", "index.html");

describe("destination paths", () => {
  let fs;
  before(async () => { fs = await import("../js/engine/fs.js"); });

  it("joins a directory and a name", () => {
    assert.equal(fs.normalizeDestination("/data", "kick.wav"), "/data/kick.wav");
    assert.equal(fs.normalizeDestination("/", "system.rb"), "/system.rb");
    assert.equal(fs.normalizeDestination("/data/drums", "a.qoa"), "/data/drums/a.qoa");
  });

  it("rejects a relative destination", () => {
    assert.throws(() => fs.normalizeDestination("data", "a.txt"), /absolute/);
  });

  it("rejects a destination that walks up", () => {
    assert.throws(() => fs.normalizeDestination("/data/../etc", "a.txt"), /\.\./);
  });

  it("rejects a name carrying a separator", () => {
    assert.throws(() => fs.normalizeDestination("/data", "../etc/env.yml"), /separator/);
    assert.throws(() => fs.normalizeDestination("/data", "sub/a.txt"), /separator/);
  });

  it("rejects an empty name", () => {
    assert.throws(() => fs.normalizeDestination("/data", ""), /empty/);
  });
});

describe("file transfer", () => {
  let h, fs, files;
  before(async () => {
    h = await boot();
    fs = await import("../js/engine/fs.js");
    files = await import("../js/engine/files.js");
  });

  it("lists the deployed rootfs and hides /dev", () => {
    const { files: entries, directories } = fs.readTree(h.Module);
    const paths = entries.map((entry) => entry.path);
    assert.ok(paths.includes("/system.rb"), "rootfs file missing from the listing");
    assert.ok(!paths.some((p) => p.startsWith("/dev")), "/dev leaked into the listing");
    assert.ok(!directories.some((d) => d.startsWith("/dev")), "/dev leaked into the directories");
    assert.ok(directories.includes("/"), "root missing from the directories");
    assert.ok(directories.includes("/data"), "/data missing from the directories");
  });

  it("uploads a file the OS can then read", async () => {
    const body = "HARUCOM-UPLOAD-OK";
    const bytes = new TextEncoder().encode(body);
    const result = await files.addFiles(h.Module, "/data", [
      { name: "upload.txt", arrayBuffer: async () => bytes.buffer },
    ]);
    assert.deepEqual(result.failed, []);
    assert.deepEqual(result.written, ["/data/upload.txt"]);
    assert.deepEqual(result.replaced, []);

    h.typeString('puts File.open("/data/upload.txt").read');
    h.hidType(h.ENTER);
    h.driveUntil(body, 20000);
    assert.ok(h.printed().includes(body), "the OS could not read the uploaded file");
  });

  it("reports a replaced file and a rejected name", async () => {
    const result = await files.addFiles(h.Module, "/data", [
      { name: "upload.txt", arrayBuffer: async () => new Uint8Array([1]).buffer },
      { name: "../escape.txt", arrayBuffer: async () => new Uint8Array([1]).buffer },
    ]);
    assert.deepEqual(result.replaced, ["/data/upload.txt"]);
    assert.equal(result.failed.length, 1);
    assert.match(result.failed[0], /escape\.txt/);
  });

  it("round-trips bytes that are not text", () => {
    const bytes = new Uint8Array([0x00, 0x01, 0x7f, 0x80, 0xff, 0x00, 0xfe]);
    fs.writeFileBytes(h.Module, "/data/nested/blob.bin", bytes);
    assert.deepEqual(Array.from(fs.readFileBytes(h.Module, "/data/nested/blob.bin")),
                     Array.from(bytes));
  });

  it("reads back a file the OS wrote", () => {
    h.typeString('f = File.open("/data/from_os.txt", "w"); f.write("out"); f.close');
    h.hidType(h.ENTER);
    h.driveUntil("=> nil", 20000);
    const bytes = fs.readFileBytes(h.Module, "/data/from_os.txt");
    assert.equal(new TextDecoder().decode(bytes), "out");
  });
});

describe("files panel", () => {
  let h, files, panel;
  before(async () => {
    h = await boot();
    files = await import("../js/engine/files.js");
    // Build the panel from index.html itself, so a renamed id there fails here
    // instead of silently breaking the page.
    const markup = nodeFs.readFileSync(INDEX_HTML, "utf8");
    const section = markup.match(/<section id="files">[\s\S]*?<\/section>/);
    assert.ok(section, "index.html has no #files section");
    document.body.insertAdjacentHTML("beforeend", section[0]);
    panel = document.getElementById("files");
  });

  it("renders the rootfs and defaults the destination to /data", () => {
    const panelFiles = files.createFiles(h.Module, panel);
    panelFiles.refresh();
    const options = Array.from(panel.querySelectorAll("#file-destination option"))
      .map((option) => option.value);
    assert.ok(options.includes("/data"));
    assert.equal(panel.querySelector("#file-destination").value, "/data");
    const rows = Array.from(panel.querySelectorAll("#file-list li .file-path"))
      .map((span) => span.textContent);
    assert.ok(rows.includes("/system.rb"));
    assert.ok(rows.length > 1);
  });

  it("is a no-op without a panel", () => {
    files.createFiles(h.Module, null).refresh();
  });
});
