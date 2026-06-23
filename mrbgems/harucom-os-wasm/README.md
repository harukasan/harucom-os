# harucom-os-wasm

WebAssembly boot entry for Harucom OS, the browser counterpart of `run_mruby()`
in `src/main.c`. Built on the upstream picoruby-wasm gem
(`PICORB_PLATFORM_POSIX`), so it carries no hardware HAL of its own.

## What it provides

- **`harucom_init()`** (C, `EMSCRIPTEN_KEEPALIVE`, called once from JavaScript):
  deploys the rootfs into the emscripten in-memory filesystem (MEMFS), prunes the
  emscripten-only directories the board does not have (see below), opens mruby,
  installs the opcode-budget preemption hook, initializes the DVI text surface and
  the IME dictionary, and creates the boot task that runs `/system.rb`. The
  scheduler is then driven from JavaScript via `mrb_run_step()` / `mrb_tick_wasm()`
  (provided by picoruby-wasm), so blocking Ruby yields back to the browser.
- **A wasm `ADC` class + `harucom_pad_set()`**: `Board::Pad`'s only hardware
  dependency. There is no ADC in the browser, so `read_raw` returns a
  resistor-ladder value JavaScript injects from the on-screen D-pads. This
  replaces the picoruby-adc gem for the wasm build.
- **Cooperative-yield overrides** (`mrblib/dvi_wasm.rb`): `DVI.wait_vsync` becomes
  a task-aware `sleep_ms`, and `DVI::Text` / `DVI::Graphics.commit` yield one frame,
  so the single browser thread stays responsive (the board uses real vsync / a
  timer interrupt instead).

## HAL

This gem has no HAL. It reuses picoruby-wasm's `global_mrb` and
`picorb_create_task()`, and the `Machine_*` bindings, the task scheduler HAL, and
the io-console / env / rng ports all come from picoruby's posix ports
(auto-compiled under `PICORB_PLATFORM_POSIX`).

## Build

The rootfs C arrays (`ruby_scripts.h`) are generated into `build/` by the wasm
`Rakefile` (the same path the board's CMake build uses), and `mrbgem.rake` adds
`build/` to this gem's include path so `harucom_wasm.c` can `#include` it. Build
and test with `rake wasm:build` / `rake wasm:test`; see
[doc/masterplan/wasm-resume-plan.md](../../doc/masterplan/wasm-resume-plan.md) for
the full wasm port design.

## Files

- `src/harucom_wasm.c` - `harucom_init()`, the ADC pad shim, rootfs deploy / prune.
- `mrblib/dvi_wasm.rb` - the cooperative-yield overrides.
- `mrbgem.rake` - gem spec and the `build/` include path.
