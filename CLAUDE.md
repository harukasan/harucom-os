# CLAUDE.md

## Project overview

Harucom OS is firmware for the Harucom Board (RP2350-based single-board computer).
It runs Ruby scripts on mruby VM with DVI output, USB keyboard input, and a file system.

- Language: C (C11), with Ruby scripts executed on the embedded VM
- Target: RP2350 (ARM Cortex-M33), built with pico-sdk
- Build system: CMake, with a Rakefile wrapper for convenience

## Build commands

```sh
rake          # configure + build (default)
rake clean    # remove build/
rake distclean # remove build/ and PicoRuby build
```

## Code style

- Follow `.editorconfig` for indentation and whitespace rules
- Use C11, K&R brace style
- Keep HAL functions prefixed with `hal_` or `mrb_hal_`

## Commit messages

- First line: summary of the change
- Following lines: concise bullet points of what was done
- Do not include trivial accompanying changes (e.g. license additions, formatting fixes)
