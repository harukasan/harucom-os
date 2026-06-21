# Cross-build configuration for running Harucom OS in a web browser via
# picoruby.wasm. WebAssembly counterpart of build_config/harucom-os-pico2.rb.
#
# Build with (from the picoruby submodule, with emcc on PATH):
#   cd lib/picoruby
#   MRUBY_CONFIG=../../build_config/harucom-wasm.rb rake
#
# This is based on the upstream build_config/picoruby-wasm.rb: it defines
# PICORB_PLATFORM_POSIX so picoruby auto-compiles every gem's ports/posix and
# ports/common sources (see lib/picoruby/lib/picoruby/build.rb), which is what
# provides the Machine_*/hal I/O, the task scheduler HAL, the io-console / env /
# rng / mbedtls ports and the picoruby-wasm runtime. The filesystem is the
# emscripten in-memory filesystem (MEMFS) via mruby-io; harucom_init deploys the
# rootfs into it (mrbgems/harucom-os-wasm).

# picoruby detects a wasm build via `wasm?`, which checks ENV['CONFIG'] /
# ENV['MRUBY_CONFIG'] against the literal "picoruby-wasm" (lib/picoruby/lib/
# picoruby/build.rb). Our config is named "harucom-wasm", so set ENV['CONFIG']
# to make `wasm?` true, which makes the stdlib gembox exclude
# picoruby-regexp_light (it conflicts with picoruby-wasm's own regexp).
# MRUBY_CONFIG is always passed explicitly, so this does not affect config-path
# resolution.
ENV['CONFIG'] = 'picoruby-wasm'

MRuby::CrossBuild.new("harucom-wasm") do |conf|
  toolchain :clang

  conf.cc.command = "emcc"
  conf.linker.command = "emcc"
  conf.archiver.command = "emar"

  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "PICORB_PLATFORM_WASM"
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=1"
  conf.cc.defines << "MRB_INT64"
  # Console and IME need UTF-8 strings (as in harucom-os-pico2.rb).
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.microruby

  # NB: we do NOT use the "minimum" gembox here. Under POSIX it pulls in the
  # picoruby-bin-microruby CLI tool, whose microruby.c defines global_mrb and so
  # collides with picoruby-wasm's global_mrb at link time. Upstream picoruby-wasm
  # avoids minimum for the same reason; we add the mruby VM explicitly instead.
  conf.gem core: "picoruby-mruby"

  # mruby-posix: the posix task/io/dir HAL and mruby-io/mruby-dir (File/Dir over
  # MEMFS). stdlib: yaml/json/etc.
  conf.gembox "mruby-posix"
  conf.gembox "stdlib"

  # Runtime infrastructure for the OS userland. machine / picorubyvm / time /
  # require arrive transitively via picoruby-wasm and picoruby-machine.
  conf.gem core: "picoruby-require"
  conf.gem core: "picoruby-env"
  conf.gem core: "picoruby-io-console"
  conf.gem core: "picoruby-sandbox"

  # DVI text/graphics. The portable text core (src/dvi_text.c) and graphics
  # drawing compile here; the browser renderer lives in ports/posix/dvi_wasm.c
  # (auto-compiled under POSIX) and blits the framebuffer to a canvas.
  conf.gem File.expand_path("../mrbgems/picoruby-dvi", __dir__)

  # Harucom boot entry: deploys the rootfs into MEMFS and boots /system.rb.
  conf.gem File.expand_path("../mrbgems/harucom-os-wasm", __dir__)

  # The PicoRuby wasm runtime: JS interop plus the mrb_run_step / mrb_tick_wasm
  # entry points the JS run loop drives, and global_mrb.
  conf.gem core: "picoruby-wasm"
end
