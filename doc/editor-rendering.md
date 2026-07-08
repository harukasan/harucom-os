# Editor Rendering

The full-screen text editor ([edit.rb](../rootfs/app/edit.rb)) renders through
DVI text mode with differential updates: each key frame redraws only the cells
that change, and syntax parsing runs on idle frames between key repeats. This
document describes the frame loop, the redraw dispatch, the windowed syntax
analysis, and the deferred recolor machinery.

## Screen Layout

| Region      | Rows        | Drawn by                                       |
|-------------|-------------|------------------------------------------------|
| Status bar  | 0           | `draw_status`, every frame                     |
| Edit region | 1 to ROWS-2 | redraw dispatch                                |
| Command bar | ROWS-1      | `draw_command_bar`, every frame                |

The status and command bars are drawn unconditionally at full width every
frame. This restores them after ring buffer scrolls, which shift all screen
rows including these two. The command bar string is composed once per IME
mode label and cached, since its content only changes when the label changes.

## Frame Loop

Each iteration of the main loop processes at most one key:

1. `Keyboard#read_char`. When no key is pending, the idle path runs deferred
   syntax work (see [Idle-Frame Syntax Work](#idle-frame-syntax-work)) and
   waits for VBlank.
2. Key handling mutates the buffer and records undo entries.
3. `adjust_vertical_scroll` and `adjust_horizontal_scroll` update the
   viewport. Scrolling is a viewport change and does not mark the buffer
   dirty.
4. The syntax window is rebuilt synchronously only when this frame's redraw
   needs fresh line offsets (see below).
5. The redraw dispatch draws the minimal set of lines.
6. The status bar, command bar, and IME overlays are drawn, then `commit`
   swaps the double-buffered VRAM at VBlank.

Key repeat arrives about every 50 ms (3 frames) while frames are 16.7 ms, so
at least one idle frame runs between repeats even during held-key scrolling.
`commit` blocks until VBlank, so each frame's scroll and draws appear
atomically (see [DVI text mode rendering](dvi/text-mode-rendering.md)).

## Redraw Dispatch

The dispatch picks the cheapest update that covers this frame's changes, in
priority order. `vdelta` is the vertical viewport movement in lines.

| Case | Screen update |
|------|---------------|
| Single-line split (Enter) | Copy the rows below the split down by one with `DVI::Text.read_line`/`write_line`, or ring scroll when the viewport moves; draw the truncated line and the new line |
| Single-line join (Backspace at column 0, Delete at end of line) | Copy the rows below the join up by one; draw the merged line and the newly exposed bottom row |
| Other structure changes (undo/redo), page-sized jumps, combined horizontal and vertical scroll | Full redraw (`draw_all_lines`) |
| Horizontal scroll | `draw_hscroll`: redraw visible lines, skipping lines blank in both the old and new viewport |
| Vertical scroll | Ring buffer scroll (`DVI::Text.scroll_up`/`scroll_down`); draw only the newly exposed lines |
| Content edit | Draw the cursor line; the recolor of other lines is deferred to idle |

Dirty levels come from
[Editor::Buffer](../lib/picoruby/mrbgems/picoruby-editor/mrblib/buffer.rb):
`:none`, `:cursor`, `:content` (single-line change), and `:structure` (line
count or multi-line change). Splits and joins mark `:structure` but bypass
the full redraw through the shift paths above, because their screen effect
is a one-row shift plus two changed lines. The shift moves text and colors
together, so the copied rows stay visually correct without a re-parse.

Horizontal scrolling jump-scrolls: when the cursor leaves the visible
window, the viewport re-centers on it, deferring the next full-width redraw
for about half a screen of further movement. Lines whose bytesize fits the
relevant width threshold skip the display width scan entirely, because a
UTF-8 character occupies at least as many bytes as display columns.

## Windowed Syntax Analysis

`RubySyntax.analyze`
([ruby_syntax.c](../mrbgems/picoruby-ruby-syntax/src/ruby_syntax.c)) rejects
sources larger than 8192 bytes, so the whole file cannot be parsed at once.
Instead a window of lines around the viewport is parsed and cached as a
bundle `[highlight_map, window_offsets, window_start]`, where
`window_offsets[k]` is the byte offset of line `window_start + k` inside the
parsed source. Lines outside the window draw as plain text.

| Constant | Value | Meaning |
|----------|-------|---------|
| `SYNTAX_MARGIN` | 40 | Lines parsed above and below the viewport |
| `SYNTAX_ANCHOR_SCAN` | 60 | Max lines scanned upward for a parse anchor |
| `SYNTAX_MAX_BYTES` | 8100 | Window byte budget, under the 8192 analyze limit |
| `SYNTAX_PREFETCH_MARGIN` | 10 | Prefetch a rebuild when this close to the window edge |

The window start anchors at a column-0 top-level boundary (`class`,
`module`, `def`, or `end`) so the parser does not start inside a string,
heredoc, or continued expression. When the byte budget overflows, the bottom
margin is trimmed first, then the top context, always keeping the viewport
covered. When the analysis fails (for example a viewport denser than the
byte budget), the window bounds are still recorded and the affected lines
draw as plain text, without retrying every frame.

The window is rebuilt synchronously only when the current frame's redraw
needs fresh line offsets:

- line offsets shifted and the frame redraws the whole screen (undo/redo
  and other multi-line structure changes), or
- the viewport left the cached window (the fallback when the prefetch did
  not run in time).

All other invalidations defer to idle frames.

Auto-indent analysis (Enter, and dedent on space after keywords) parses its
own window around the cursor with no margin below it, because the
indentation of a line depends only on the lines above. This parse stays
synchronous because the cursor position depends on the inserted indent.

## Idle-Frame Syntax Work

The idle path (no key pending) performs the deferred parsing:

- **Deferred recolor.** Content edits, splits, and joins mark the window
  stale instead of re-parsing. `stale_syntax` keeps the bundle the screen
  was last drawn with. The idle frame re-parses, then
  `sync_highlight_changes` compares each visible line's highlight bytes
  between the stale bundle and the fresh one (per-line `byteslice`
  compares) and redraws only the lines that differ. A recolor that spans
  many lines, for example a typed quote that turns the rest of the screen
  into a string, therefore lands on an idle frame instead of the keystroke
  frame.
- **Prefetch.** When the viewport comes within `SYNTAX_PREFETCH_MARGIN`
  lines of the window edge, the window is rebuilt ahead of the crossing, so
  the parse cost lands between key repeats. The prefetch runs once per
  scroll position, because a byte-budget-trimmed window can stay near the
  edge even after a rebuild.

Idle work is skipped while an IME preedit overlay is shown, since redrawing
its line would erase the overlay; the recolor runs after the composition
ends.

### Consistency Invariant and Transients

The screen is always consistent with one bundle: `syntax` when fresh, or
`stale_syntax` while stale. The idle diff compares against that base, so
deferred recolors converge regardless of how many edits happened in
between. Two visual transients are accepted, each lasting until the next
idle frame (a few frames at most):

- Lines exposed by scrolling while stale draw with the stale bundle, whose
  per-line offsets can be off by the shifted line count after a split or
  join.
- A full redraw triggered while stale (for example a carried dirty flag
  right after a split) paints with the stale bundle. The screen stays
  consistent with the stale base, so the idle diff corrects it.

## Drawing Hot Paths

`RubySyntax.draw_line` ([ruby_syntax.rb](../rootfs/lib/ruby_syntax.rb)) runs
for every highlighted line on every redraw. It tracks attribute spans as
byte ranges and emits each span with a single `byteslice`, and derives the
UTF-8 character length from the lead byte inline, so the per-character loop
makes no method calls and performs no string concatenation. The IRB line
editor ([line_editor.rb](../rootfs/lib/line_editor.rb)) shares this code.

## References

- [DVI text mode rendering](dvi/text-mode-rendering.md): text VRAM layout,
  ring buffer scroll, double-buffered commit
- [Keyboard input](keyboard-input.md): input queue and key repeat timing
- [Editor::Buffer improvements](editor-buffer-improvements.md): buffer dirty
  levels and planned buffer work
