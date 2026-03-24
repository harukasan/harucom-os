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

**When changing `build_config/*.rb` (adding/removing gems, changing defines)
or adding new `MRB_SYM()` identifiers in C code, you must run
`rake distclean` before `rake`.** `rake clean` only removes the CMake build
directory; it does not rebuild `libmruby.a` or regenerate the presym table.
The PicoRuby build cache is separate and only cleared by `distclean`.

## Documentation

Design documents and implementation notes are in `doc/`:

- [doc/psram.md](doc/psram.md) — PSRAM driver (APS6404L, QMI CS1 initialization, XIP mapping)
- [doc/dvi.md](doc/dvi.md) — DVI output (HSTX, DMA, text/pixel modes, stability analysis)
- [doc/dvi/batch-rendering.md](doc/dvi/batch-rendering.md) — Batch scanline rendering (N=4, line buffers, descriptor layout)
- [doc/dvi/text-mode-rendering.md](doc/dvi/text-mode-rendering.md) — Text mode rendering (VRAM, font cache, scanline renderer)
- [doc/dvi/stability.md](doc/dvi/stability.md) — DVI stability analysis (bus contention, flash write safety, diagnostics)
- [doc/usb-host-keyboard.md](doc/usb-host-keyboard.md) — USB host keyboard (PIO-USB, HID, Ruby/C API)
- [doc/keyboard-input.md](doc/keyboard-input.md) — Keyboard input (background polling task, input queue, Ctrl-C interrupt, key repeat)
- [doc/filesystem.md](doc/filesystem.md) — FAT filesystem on flash (FatFs, VFS, flash write safety)
- [doc/editor-buffer-improvements.md](doc/editor-buffer-improvements.md) — Editor::Buffer improvement plan (desired column, tab width)

## Documentation style

Documents in `doc/` follow this structure:

```markdown
# Title

Brief overview (2-3 sentences). Link libraries and specs on first mention
using reference-style links (e.g. [Pico-PIO-USB][pio-usb]).

## Ruby API

Module: `Module::Name`

- [Method.one](#methodone)
- [Method.two](#methodtwo---returntype)

Module overview: what it provides and how to use it, with a code example.

### Module::Name.method_one

Description of the method.

### Module::Name.method_two -> ReturnType

Description with return value.

## C API

Defined in [header.h](../path/to/header.h).

### function_name

\```c
void function_name(void);
\```

Description of the function.

## Hardware Configuration

Pin assignments (table with constants from board header), port assignments.

## Architecture

Narrative sections with tables and bullet lists where appropriate.
Each subsection opens with a sentence explaining what it covers.

## References

- [Name][ref-id]: Description
```

Guidelines:
- Use reference-style links (`[text][id]`) for external URLs; define them near first use
- Link source files with relative paths (e.g. `[header.h](../path/to/header.h)`)
- API sections list each method/function with signature and description
- Architecture uses narrative prose; use bullet lists and tables for structured data

## Code style

- Follow `.editorconfig` for indentation and whitespace rules
- Use C11, K&R brace style
- Keep HAL functions prefixed with `hal_` or `mrb_hal_`
- Write documents in `doc/` in English
- Documents describe the current state only, not historical changes or comparisons with previous implementations
- Do not use em dashes (--) in comments or documentation; use commas, periods, or parentheses instead
- Prefer full names over abbreviations in API naming (e.g. `pixel` not `px`, `framebuffer` not `fb`)

## Hardware notes

- **Flash: 128 Mbit (16 MB).** The linker script currently limits FLASH to
  4 MB, but the actual chip capacity is much larger. Flash storage size is
  not a constraint. Prefer data structures that minimize flash read count
  (e.g. direct lookup tables) over compact representations that require
  many accesses (e.g. binary search).
- **PSRAM: 8 MB (APS6404L).** Mapped via QMI CS1 at `0x11000000`. Used for
  the mruby heap.

## Common pitfalls

- **PicoRuby presym files are auto-generated.** Do not edit files under
  `lib/picoruby/build/` or presym tables by hand. They are regenerated
  by the build system.
- **IDE clang diagnostics are unreliable before building.** This is a
  cross-compiled RP2350 project. The IDE's clang cannot resolve
  pico-sdk include paths or target-specific headers. Errors shown in the
  IDE (e.g. "undeclared identifier") may be false positives. Always run
  `rake` to confirm real build errors.
- **`lib/picoruby` submodule may show as "modified content" in git status.**
  `rake distclean` recreates `lib/picoruby/build/.gitignore` to prevent
  this issue. If it still appears, do not stage or commit the submodule.

## Commit messages

- First line: summary of the change
- Following lines: concise bullet points explaining the purpose of each change
- Each bullet should be purpose-driven, not just describe the action (e.g. "Add X to achieve Y", not "Add X")
- Do not include trivial accompanying changes (e.g. license additions, formatting fixes)
