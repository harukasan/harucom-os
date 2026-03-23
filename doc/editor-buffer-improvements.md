# Editor::Buffer Improvements

Planned improvements to [Editor::Buffer][buffer] for the text editor
and other Buffer consumers (LineEditor, etc.).

[buffer]: ../lib/picoruby/mrbgems/picoruby-editor/mrblib/buffer.rb

## Desired Column on Vertical Movement

Buffer's `up`/`down` methods move `cursor_y` but leave `cursor_x`
unchanged. When moving from a long line to a short line and back,
the original column position is lost because `cursor_x` is clamped
to the shorter line's byte length.

Most editors remember a "desired display column" across vertical
movements. The fix adds `@desired_col` to Buffer:

- `up`/`down`: Convert `cursor_x` to display column on the first
  vertical move. On the destination line, convert back to byte
  position via `Editor.display_col_to_byte`, clamping to line end.
- `left`/`right`/`head`/`tail`/`put` (String): Reset
  `@desired_col = nil` so the next vertical move starts fresh.

This requires changes to picoruby-editor (submodule). An alternative
is to handle it in the editor application, but that duplicates
Buffer's cursor logic.

## Delete at End of Line

`delete` removes the character at `cursor_x` within the current line
but does nothing when the cursor is at the end of a line. In contrast,
`put(:BSPACE)` at the beginning of a line joins it with the previous
line. `delete` should mirror this behavior: when the cursor is at the
end of a line, append the next line to the current line and remove it.

The text editor currently works around this in application code
(`rootfs/app/edit.rb`). Moving the logic into Buffer makes it
consistent with Backspace and removes the need for the workaround.

## Tab Width

`put(:TAB)` inserts two spaces unconditionally:

```ruby
when :TAB
  put " "
  put " "
```

Improvements:

- Make tab width configurable (default 2, support 4 and 8).
- Align to the next tab stop rather than inserting a fixed number
  of spaces. The tab stop column is `(current_display_col / width + 1) * width`.
