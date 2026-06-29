// Ctrl-Alt-Delete reboot: the wasm USB-host shim (usb_host_wasm.c) detects that
// chord in the HID report and calls window.__harucomReboot (the browser sets it
// to location.reload). This mirrors the board, which watchdog_reboots in its HID
// report callback. The test installs a spy hook instead of reloading.
const { describe, it, before } = require("node:test");
const assert = require("node:assert/strict");
const { boot } = require("./harness.cjs");

describe("Ctrl-Alt-Delete reboot", () => {
  let h;
  before(async () => { h = await boot(); });

  it("fires the reboot hook only for Ctrl+Alt+Delete", () => {
    let reboots = 0;
    globalThis.window.__harucomReboot = () => { reboots++; };

    // Ctrl (0x01) + Alt (0x04) modifier with the Delete usage (0x4C) held.
    h.Module._harucom_kbd_set_state(0x05, 0x4c, 0, 0, 0, 0, 0);
    assert.equal(reboots, 1, "Ctrl+Alt+Delete reboots");

    // Ctrl+Alt without Delete does not reboot.
    h.Module._harucom_kbd_set_state(0x05, 0x04, 0, 0, 0, 0, 0);
    // Delete without Ctrl+Alt does not reboot.
    h.Module._harucom_kbd_set_state(0x00, 0x4c, 0, 0, 0, 0, 0);
    assert.equal(reboots, 1, "only the full chord reboots");

    delete globalThis.window.__harucomReboot;
  });
});
