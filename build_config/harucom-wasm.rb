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

  # Enable the per-opcode code_fetch_hook so harucom_wasm.c can install an
  # opcode-budget preemption hook. The board preempts tasks with a timer
  # interrupt; the browser main thread cannot be interrupted, so the hook
  # simulates the timeslice and keeps busy Ruby loops from freezing the tab.
  conf.cc.defines << "MRB_USE_DEBUG_HOOK"

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

  # Userland support gems pulled in by rootfs/system.rb. picoruby-editor is an
  # upstream pure-Ruby gem (Editor / Editor::Buffer, used by line_editor.rb).
  conf.gem core: "picoruby-editor"

  # USB host (USB::Host) and the Keyboard class on top of it. usb-host ships
  # only a ports/rp2350 hardware driver, so the browser build supplies its own
  # ports/posix/usb_host_wasm.c that returns JS-injected key state.
  conf.gem File.expand_path("../mrbgems/picoruby-usb-host", __dir__)
  conf.gem File.expand_path("../mrbgems/picoruby-keyboard-input", __dir__)

  # RubySyntax.analyze (Prism-based highlight/indent) used by the line editor.
  conf.gem File.expand_path("../mrbgems/picoruby-ruby-syntax", __dir__)

  # Japanese IME dictionary (InputMethod.dict_available?/skk_lookup/tcode_lookup).
  # The HCDK image is read from flash via XIP on the board; the browser port
  # (ports/posix/dict_region.c) loads it from the emcc-embedded /dict.bin.
  conf.gem File.expand_path("../mrbgems/harucom-os-dict", __dir__)

  # PWM audio synth (PWMAudio). The synth/ring buffer in src/ is portable; the
  # browser port (ports/posix/pwm_audio_wasm.c) drains the ring to Web Audio
  # instead of the board's PWM timer ISR.
  conf.gem File.expand_path("../mrbgems/picoruby-pwm-audio", __dir__)

  # Harucom boot entry: deploys the rootfs into MEMFS and boots /system.rb.
  conf.gem File.expand_path("../mrbgems/harucom-os-wasm", __dir__)

  # The PicoRuby wasm runtime: JS interop plus the mrb_run_step / mrb_tick_wasm
  # entry points the JS run loop drives, and global_mrb.
  conf.gem core: "picoruby-wasm"
end
