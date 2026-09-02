// Loads the built shell bundle (build/wasm/ui/main.js) in a jsdom page.
//
// The React sources have their own unit tests (rake wasm:ui_test), which run
// against the TypeScript. This one runs against the artifact the browser
// actually fetches, so it catches the ways a build can be wrong while every
// source test still passes: a bundle that throws on load, a page that never
// mounts, an entry that does not find #app.
//
// The module factory is stubbed to reject, which is the one path that needs no
// canvas 2D context (jsdom has none without node-canvas). That still proves the
// bundle parses, React mounts, the canvas is hosted and the log is adopted.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");
const { JSDOM } = require("jsdom");

const BUNDLE = path.join(__dirname, "..", "..", "build", "wasm", "ui", "main.js");

describe("shell bundle", () => {
  let document;

  before(async () => {
    assert.ok(fs.existsSync(BUNDLE), `${BUNDLE} not found. Run \`rake wasm:build\` first.`);
    const dom = new JSDOM('<!DOCTYPE html><div id="app"></div>', { pretendToBeVisual: true });
    globalThis.window = dom.window;
    globalThis.document = document = dom.window.document;
    globalThis.navigator = dom.window.navigator;
    globalThis.HTMLElement = dom.window.HTMLElement;
    dom.window.createHarucomModule = () => Promise.reject(new Error("stubbed"));

    await import(pathToFileURL(BUNDLE).href);
    // React renders in a microtask even under flushSync's caller, so let the
    // rejection handler and the mount both settle.
    await new Promise((resolve) => setTimeout(resolve, 50));
  });

  it("mounts into #app", () => {
    assert.ok(document.getElementById("app").firstElementChild, document.body.innerHTML);
  });

  it("hosts the screen canvas inside the shell", () => {
    const canvas = document.querySelector("#app canvas#screen");
    assert.ok(canvas, "the canvas is inside the mounted shell: " + document.body.innerHTML);
    assert.equal(canvas.width, 640);
    assert.equal(canvas.height, 480);
  });

  it("reports a failed module load in the log rather than dying silently", () => {
    assert.match(document.querySelector("#app pre").textContent, /failed to load the wasm module/);
  });
});
