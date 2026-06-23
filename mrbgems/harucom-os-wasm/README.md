# harucom-os-wasm

WebAssembly boot entry for Harucom OS, the browser counterpart of `src/main.c`,
built on the picoruby-wasm gem (`PICORB_PLATFORM_POSIX`).

It exports `harucom_init()` to JavaScript (deploys the rootfs into the emscripten
MEMFS and boots mruby), adds the wasm `ADC` pad shim in place of picoruby-adc, and
overrides `DVI.wait_vsync` / `commit` (`mrblib/dvi_wasm.rb`) to yield cooperatively
to the browser run loop.
