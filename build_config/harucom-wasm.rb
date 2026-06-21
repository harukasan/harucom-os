# Cross-build configuration for running Harucom OS in a web browser via
# picoruby.wasm. This is the WebAssembly counterpart of
# build_config/harucom-os-pico2.rb.
#
# Build with (from the picoruby submodule, with emcc on PATH):
#   cd lib/picoruby
#   MRUBY_CONFIG=../../build_config/harucom-wasm.rb rake
#
# Output: lib/picoruby/build/harucom-wasm/lib/libmruby.a and the emscripten
# link product contributed by the picoruby-wasm gem
# (build/harucom-wasm/bin/picoruby.js + .wasm).
#
# Relative to harucom-os-pico2.rb this drops every RP2350-specific setting
# (MRB_32BIT, -fshort-enums, the est-allocator, link-time RO data, the
# arm-none-eabi toolchain) and adopts the emscripten toolchain from the
# upstream build_config/picoruby-wasm.rb.
#
# Like the board build (harucom-os-pico2.rb) this does NOT define
# PICORB_PLATFORM_POSIX, so the core gembox provides the picoruby-vfs +
# picoruby-littlefs filesystem stack the bootstrap mounts at "/", rather than
# the WASI/posix filesystem the upstream picoruby-wasm config uses.
#
# The gem set is grown in phases (see the plan):
#   Phase 0 (this file): portable infrastructure gems only, to prove the stack
#     compiles and links under emcc and produces a .wasm.
#   Phase 1+: add a harucom wasm entry/HAL gem (RAM littlefs HAL, hal_machine,
#     hal_task, init_rootfs, /system.rb bootstrap) so it boots to an IRB prompt.
#   Phase 2+: add picoruby-dvi (ports/wasm canvas renderer), picoruby-usb-host,
#     picoruby-keyboard-input, picoruby-ruby-syntax, picoruby-pwm-audio and
#     harucom-os-dict.

# picoruby's build helper detects a wasm build via `wasm?`, which checks
# ENV['CONFIG'] / ENV['MRUBY_CONFIG'] against the literal "picoruby-wasm" (see
# lib/picoruby/lib/picoruby/build.rb). Our config is named "harucom-wasm", so we
# set ENV['CONFIG'] here to make `wasm?` true. This is what makes the stdlib
# gembox exclude picoruby-regexp_light, which conflicts with picoruby-wasm's own
# regexp. MRUBY_CONFIG is always passed explicitly, so this does not affect
# config-path resolution.
ENV['CONFIG'] = 'picoruby-wasm'

MRuby::CrossBuild.new("harucom-wasm") do |conf|
  toolchain :clang

  conf.cc.command = "emcc"
  conf.linker.command = "emcc"
  conf.archiver.command = "emar"

  # Platform and VM configuration. Mirrors build_config/picoruby-wasm.rb (minus
  # PICORB_PLATFORM_POSIX, see header) plus MRB_UTF8_STRING which the Console and
  # IME paths require (as in harucom-os-pico2.rb).
  conf.cc.defines << "PICORB_PLATFORM_WASM"
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=1"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.microruby

  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"

  # Portable runtime infrastructure not already provided by the gemboxes.
  # (require, machine, picorubyvm, time, vfs, littlefs, watchdog come from the
  # core gembox; yaml/json from stdlib.)
  conf.gem core: "picoruby-env"
  conf.gem core: "picoruby-io-console"
  conf.gem core: "picoruby-sandbox"

  # Harucom wasm HAL: provides the wasm implementations of the hal.h I/O
  # interface, the Machine_* functions, the mruby-task HAL and the
  # picoruby-io-console port (sigint_status, hal_write, io_raw_q, ...).
  conf.gem File.expand_path("../mrbgems/harucom-os-wasm", __dir__)

  # JS interop, the emscripten link task, and the default wasm entry points
  # (picorb_init / mrb_run_step / mrb_tick_wasm). Phase 1 introduces a
  # harucom-specific entry that boots /system.rb instead of suspending.
  conf.gem core: "picoruby-wasm"
end
