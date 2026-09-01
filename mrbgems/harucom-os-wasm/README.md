# harucom-os-wasm

WebAssembly boot entry for Harucom OS, the browser counterpart of `src/main.c`.
Built on the picoruby-wasm gem (`PICORB_PLATFORM_POSIX`).

- Exports `harucom_init()` to JavaScript. It deploys the rootfs into the
  emscripten MEMFS and boots mruby.
- Installs an opcode-budget preemption hook, so a Ruby loop that never yields
  cannot freeze the browser tab.
- Overrides `DVI.wait_vsync` and `commit` (`mrblib/dvi_wasm.rb`) to yield
  cooperatively to the browser run loop.
