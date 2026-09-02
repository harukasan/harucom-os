# WebAssembly Build

Harucom OS also builds for the browser. The same C sources and the same
`rootfs/` userland are cross-compiled with [emscripten][emscripten] against
[picoruby-wasm][picoruby-wasm], so one mruby VM runs the OS in a page: the DVI
text and graphics modes paint a canvas, DOM key events arrive as USB HID
reports, and the filesystem is the emscripten in-memory filesystem (MEMFS).
The board build is unaffected. The browser only adds `ports/posix` sources and
a separate build config.

## Build

The browser build needs `emcc` on PATH and the picoruby submodule checked out
with its own submodules (`git submodule update --init --recursive`).

| Command | Description |
| --- | --- |
| `rake wasm:build` | Build `build/wasm/harucom.{js,wasm}` and stage the page next to it. `CLEAN=1` rebuilds the presym and host tools from scratch. |
| `rake wasm:server` | Serve `build/wasm/` on `http://localhost:8000/` (`PORT=` to change). Edits to `wasm/index.html`, `wasm/style.css` and `wasm/js/` are restaged while it runs, so a plain reload picks them up. |
| `rake wasm:test` | Run the headless smoke tests under Node. Needs `npm install` in `wasm/` once (jsdom). |
| `rake wasm:clean` | Remove `build/wasm/` and the picoruby wasm build. |

`build_config/harucom-wasm.rb` is the emscripten counterpart of
`build_config/harucom-os-pico2.rb`. It defines `PICORB_PLATFORM_POSIX`, so
picoruby compiles each gem's `ports/posix` and supplies the posix `Machine`,
task scheduler, io-console, env and rng ports. `MRB_INT64` needs `MRB_NO_BOXING`
on this 32-bit target, which also keeps full `Float` precision.

## C API

The browser module exports these to JavaScript.

### harucom_init

```c
int harucom_init(void);
```

Deploy the rootfs into MEMFS, open the VM, install the preemption hook,
initialize the DVI surface and enqueue `/system.rb` as the boot task. Returns 0
on success. Defined in
[harucom_wasm.c](../mrbgems/harucom-os-wasm/src/harucom_wasm.c).

### harucom_kbd_set_state

```c
void harucom_kbd_set_state(uint8_t modifier, uint8_t k0, uint8_t k1, uint8_t k2,
                           uint8_t k3, uint8_t k4, uint8_t k5);
```

Replace the whole HID keyboard report. `Keyboard#poll` reads it exactly as it
reads a hardware report on the board. Defined in
[usb_host_wasm.c](../mrbgems/picoruby-usb-host/ports/posix/usb_host_wasm.c).

### harucom_dvi_framebuffer

```c
uint8_t *harucom_dvi_framebuffer(void);
uint32_t harucom_dvi_frame_count(void);
int harucom_dvi_width(void);
int harucom_dvi_height(void);
```

The RGB332 framebuffer the canvas blits, its 640x480 dimensions, and a counter
bumped on every commit so the run loop can skip unchanged frames. Defined in
[dvi_wasm.c](../mrbgems/picoruby-dvi/ports/posix/dvi_wasm.c).

### harucom_audio_pull

```c
int harucom_audio_pull(float *out_l, float *out_r, int frames);
```

Render `frames` stereo frames into two planar float channels and advance the
sample clock by what it produced. Rendering is on demand, so it always produces
`frames`. `harucom_audio_sample_rate()` returns the synth rate the caller should
resample from. Defined in
[pwm_audio_wasm.c](../mrbgems/picoruby-pwm-audio/ports/posix/pwm_audio_wasm.c).

### harucom_pad_set

```c
void harucom_pad_set(int pad, int raw);
```

Set what pad 0 or 1 reads, as a 12-bit ADC value. Out-of-range values are
ignored. Defined in
[harucom_wasm.c](../mrbgems/harucom-os-wasm/src/mruby/harucom_wasm.c).

## Architecture

### Boot

`index.html` loads `harucom.js` (the emscripten module) and then `js/main.js`.
`main.js` creates the module, wires `Module.print` / `printErr` to the `#log`
element, composes the Engine and calls `engine.start()`, which runs
`harucom_init`, prunes the emscripten-only directories (`/home`, `/tmp`,
`/proc`) so the filesystem root matches the board, and starts the run loop.

`harucom_init` writes the rootfs into MEMFS on every page load, because MEMFS
starts empty each time. The board instead hash-gates a deploy against its
LittleFS copy in flash.

### Engine

`js/engine/index.js` is the only window onto the runtime. It composes the device
modules so the page never calls `Module._harucom_*` itself.

| Module | Responsibility |
| --- | --- |
| `display.js` | RGB332 framebuffer to canvas `ImageData` blit |
| `hid.js` | `KeyboardEvent.code` to USB HID usage tables (DOM free) |
| `key-report.js` | HID report state machine, held keys and deferred releases (DOM free) |
| `keyboard.js` | DOM key events to report calls, canvas focus |
| `runloop.js` | Clock ticks and scheduler steps from `requestAnimationFrame` |
| `fs.js` | MEMFS cleanup so `ls /` matches the board |

### Run loop

`requestAnimationFrame` drives the mruby task scheduler. Each frame advances
`mrb_tick_wasm` to match real elapsed time at the 4 ms tick unit (capped, so
returning from a background tab does not replay a long backlog), runs a batch of
`mrb_run_step` slices, applies the key releases deferred from that frame, and
blits the canvas when the DVI frame count changed.

Deferring releases matters because a key pressed and released inside one frame
must still be in the report when the Ruby keyboard task polls, or the keystroke
is lost.

### Preemption

The board expires a task's timeslice from a 1 ms timer interrupt. The browser
main thread cannot be interrupted, so a Ruby loop that never yields would freeze
the tab. Instead the VM's per-opcode `code_fetch_hook` counts opcodes and
requests a task switch after a budget, which makes the wasm scheduler preemptive
like the board.

The hook only requests the switch. The VM decides when to take it: a pending
switch is deferred while execution is across a C call boundary, while an
exception is in flight and during an ObjectSpace walk. That matters here because
a task switch yields by returning from `mrb_vm_exec`, and returning from a
re-entrant call would corrupt the C caller and, under emscripten
setjmp/longjmp, escape as a fatal throw.

### Yielding for the display

The browser has no vsync, so `DVI.wait_vsync` sleeps about one frame instead
(`mrblib/dvi_wasm.rb`). `DVI::Text.commit` and `DVI::Graphics.commit` yield the
same way, so a render loop that commits every iteration runs at the display rate
rather than starving the rest of the page.

### IME dictionary

The board reads the HCDK dictionary image in place from a separate flash region
through XIP. The browser has no XIP, so `rake wasm:build` builds the raw image
(`vendor/harucom-os-dict/build/dict.bin`), emcc embeds it into MEMFS with
`--embed-file`, and `dict_wasm_init` loads it into one heap buffer at boot. The
image is position independent (every offset is relative to the header), so the
lookup code is the same on both platforms and only the base pointer differs.

If the image is missing, `dict_available()` reports false rather than failing,
and the IME behaves as it does on a board with no dictionary flashed.

### Audio

The synth, mixer and ring buffer are portable and compile unchanged. Only the
output stage differs. The board renders ahead of a PWM timer ISR that consumes
the ring at a fixed rate. The browser has no such ISR, so
`ports/posix/pwm_audio_wasm.c` renders on demand: `harucom_audio_pull` asks
`pwm_audio_render_block` for exactly the frames JavaScript wants and advances
the sample clock by what it produced. Rendering therefore cannot underrun, and
`pwm_audio_stats` reports a healthy, drift-free state.

On the JavaScript side an AudioWorklet plays on the audio thread, so a long VM
frame cannot interrupt playback. `engine/audio.js` pulls from the synth ring
once per rAF frame, resamples with a continuous fractional position when the
AudioContext will not run at the synth rate, and posts frames to keep the
worklet buffered. Supply is paced by wall clock rather than by the worklet's
reported level, because those reports arrive late when the main thread is busy
and a level-only scheme then starves the worklet.

An AudioContext can only start from a user gesture, so audio arms itself on a
canvas click or the first keystroke.

### Not ported yet

The ADC pads have no `ports/posix` implementation, so `Board::Pad` and the pad
demo are unavailable in the browser.

### Differences from the board

| Area | Board | Browser |
| --- | --- | --- |
| Filesystem | LittleFS on flash, mounted through VFS | MEMFS, redeployed from the embedded rootfs on every load |
| Display | HSTX and DMA scanline renderer | `render_text` into an RGB332 framebuffer, blitted to a canvas |
| Keyboard | PIO-USB HID host | DOM key events converted to a HID report |
| Audio | PWM timer ISR consumes the ring | AudioWorklet, drained on demand |
| Reboot | Watchdog | Page reload (`window.__harucomReboot`) |
| Preemption | 1 ms timer interrupt | Opcode budget in `code_fetch_hook` |

The DVI text core itself is shared: `mrbgems/picoruby-dvi/src/dvi_text.c` holds
the cell writers, the narrow font cache and the palette, and each platform port
supplies only the VRAM storage and the renderer.

## Testing

`rake wasm:test` runs `wasm/tests/*.test.cjs` on the Node `node:test` runner.
`harness.cjs` boots one VM per test file, drives the scheduler until the IRB
banner appears, and exposes helpers to inject HID reports. picoruby-wasm
initializes its JS interop against `window` and `document`, so the harness
installs a jsdom DOM first. The tests cover the boot path (every `require`
resolved), the rendered framebuffer, and a keystroke evaluated end to end
through the keyboard pipeline into IRB.

## References

- [emscripten][emscripten]: The C to WebAssembly toolchain
- [picoruby-wasm][picoruby-wasm]: PicoRuby's browser runtime and JS interop

[emscripten]: https://emscripten.org/
[picoruby-wasm]: https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-wasm
