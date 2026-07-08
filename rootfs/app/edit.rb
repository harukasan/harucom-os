# edit: Full-screen text editor
#
# Usage from IRB:
#   edit /path/to/file.rb
#
# Keybindings:
#   Ctrl-S: Save
#   Ctrl-Q: Quit
#   Ctrl-Z: Undo
#   Ctrl-Y: Redo
#   Arrow keys, Home, End: Cursor movement
#   Backspace, Delete: Character deletion
#   Enter: Insert new line
#   PageUp, PageDown: Scroll by page

console  = $console
keyboard = $keyboard

# Screen layout
COLS        = Console::COLS
ROWS        = Console::ROWS
STATUS_ROW  = 0
EDIT_TOP    = 1
EDIT_BOTTOM = ROWS - 2
EDIT_ROWS   = EDIT_BOTTOM - EDIT_TOP + 1
COMMAND_ROW = ROWS - 1

STATUS_ATTR  = 0x0F # black on white (inverted)
COMMAND_ATTR = 0x0F
EDIT_ATTR    = 0xF0 # white on black

# State
buffer = Editor::Buffer.new
filepath = ARGV[0]
scroll_top = 0
scroll_left = 0
running = true
message = nil

# Syntax analysis state (highlighting and indentation)
#
# RubySyntax.analyze rejects sources larger than 8192 bytes, so the whole file
# cannot be parsed at once. Instead a window of lines around the viewport is
# parsed and cached. The window is rebuilt on content edits and whenever the
# viewport scrolls outside it. SYNTAX_MARGIN lines of headroom above and below
# absorb normal scrolling so a rebuild fires roughly once per that many
# scrolled lines.
highlight_enabled = filepath && filepath.end_with?(".rb")
SYNTAX_MARGIN      = 40 # extra lines parsed above/below the viewport
SYNTAX_ANCHOR_SCAN = 60 # max lines scanned upward to find a parse anchor
SYNTAX_MAX_BYTES   = 8100 # window source byte budget, under the 8192 analyze limit
syntax = nil       # [highlight_map, window_offsets, window_start] or nil
window_start = 0   # first line index covered by the parsed window
window_end = 0     # one past the last line index covered (exclusive)

# Undo stack
# Each entry: [:insert, y, x, text] | [:delete, y, x, text]
#           | [:split, y, x]        | [:join, y, x]
UNDO_MAX = 200
undo_stack = []
redo_stack = []

def undo_record(undo_stack, entry)
  last = undo_stack[-1]
  if last && entry[0] == :insert && last[0] == :insert &&
     entry[1] == last[1] && entry[2] == last[2] + last[3].bytesize
    # Consecutive insert on same line: extend text
    last[3] += entry[3]
    return
  end
  if last && entry[0] == :delete && last[0] == :delete &&
     entry[1] == last[1] && entry[2] == last[2]
    # Consecutive forward delete at same position: append text
    last[3] += entry[3]
    return
  end
  if last && entry[0] == :delete && last[0] == :delete &&
     entry[1] == last[1] && entry[2] + entry[3].bytesize == last[2]
    # Consecutive backspace: prepend text and update position
    last[2] = entry[2]
    last[3] = entry[3] + last[3]
    return
  end
  undo_stack.push(entry)
  undo_stack.shift if undo_stack.length > UNDO_MAX
end

def undo_record_break(undo_stack)
  # Insert a nil marker to break grouping
  undo_stack.push(nil) if undo_stack[-1] != nil && undo_stack.length > 0
end

def apply_entry(buffer, entry)
  type, y, x, text = entry
  case type
  when :insert
    buffer.move_to(x, y)
    line = buffer.lines[y]
    buffer.lines[y] = line.byteslice(0, x).to_s + text + line.byteslice(x, 65535).to_s
    buffer.move_to(x + text.bytesize, y)
  when :delete
    buffer.move_to(x, y)
    line = buffer.lines[y]
    buffer.lines[y] = line.byteslice(0, x).to_s + line.byteslice(x + text.bytesize, 65535).to_s
  when :split
    line = buffer.lines[y]
    buffer.lines[y] = line.byteslice(0, x).to_s
    buffer.lines.insert(y + 1, line.byteslice(x, 65535).to_s)
    buffer.move_to(0, y + 1)
  when :join
    buffer.lines[y] = buffer.lines[y] + buffer.lines[y + 1]
    buffer.lines.delete_at(y + 1)
    buffer.move_to(x, y)
  end
  buffer.mark_dirty(:structure)
  buffer.changed = true
end

def reverse_type(type)
  case type
  when :insert then :delete
  when :delete then :insert
  when :split then :join
  when :join then :split
  end
end

def perform_undo(buffer, undo_stack, redo_stack)
  undo_stack.pop while undo_stack[-1] == nil && undo_stack.length > 0
  entry = undo_stack.pop
  return false unless entry
  reversed = [reverse_type(entry[0]), entry[1], entry[2], entry[3]]
  apply_entry(buffer, reversed)
  redo_stack.push(entry)
  true
end

def perform_redo(buffer, undo_stack, redo_stack)
  entry = redo_stack.pop
  return false unless entry
  apply_entry(buffer, entry)
  undo_stack.push(entry)
  true
end

# Load file
if filepath && File.exist?(filepath)
  content = File.open(filepath, "r") { |f| f.read }
  if content
    lines = content.split("\n")
    buffer.lines.clear
    lines.each { |l| buffer.lines.push(l) }
    buffer.lines.push("") if buffer.lines.empty?
  end
  buffer.changed = false
end

# A line that begins at column 0 with a top-level construct boundary is a safe
# place to start parsing: it is not a continuation of a string, heredoc, or
# expression carried over from a previous line.
def syntax_anchor?(line)
  return false if line.bytesize == 0
  b0 = line.getbyte(0)
  return false if b0 == 0x20 || b0 == 0x09 # leading whitespace: nested/continuation
  return true if line == "end"
  line.start_with?("class ", "class\t", "module ", "module\t", "def ", "def\t")
end

# Find a parse anchor at or above from_line, scanning up to SYNTAX_ANCHOR_SCAN
# lines. Falls back to the scan limit when no anchor is found.
def syntax_anchor_line(buffer, from_line)
  from_line = 0 if from_line < 0
  limit = from_line - SYNTAX_ANCHOR_SCAN
  limit = 0 if limit < 0
  i = from_line
  while i > limit
    line = buffer.lines[i]
    return i if line && syntax_anchor?(line)
    i -= 1
  end
  limit
end

# Parse a window of lines covering [top, bottom] (absolute line indices) plus
# margins, capped to SYNTAX_MAX_BYTES. Returns [result, syntax, window_start,
# window_end] where syntax is [highlight_map, window_offsets, window_start] (or
# nil if parsing failed). window_offsets[k] is the byte offset of line
# (window_start + k) within the parsed window source.
#
# margin_below can be reduced when only indent levels are needed: the
# indentation of a line is determined by the constructs opened above it, so
# lines below it add parse cost without changing the result.
def analyze_window(buffer, top, bottom, margin_below = SYNTAX_MARGIN)
  lines = buffer.lines
  n = lines.length
  return [nil, nil, 0, 0] if n == 0
  top = 0 if top < 0
  bottom = n - 1 if bottom > n - 1
  bottom = top if bottom < top

  window_start = syntax_anchor_line(buffer, top - SYNTAX_MARGIN)
  window_end = bottom + margin_below + 1
  window_end = n if window_end > n

  total = 0
  i = window_start
  while i < window_end
    total += lines[i].bytesize + 1
    i += 1
  end
  # Trim the bottom margin, then the top context, to fit the byte budget while
  # always keeping the requested [top, bottom] range covered.
  while total > SYNTAX_MAX_BYTES && window_end > bottom + 1
    window_end -= 1
    total -= lines[window_end].bytesize + 1
  end
  while total > SYNTAX_MAX_BYTES && window_start < top
    total -= lines[window_start].bytesize + 1
    window_start += 1
  end

  source = lines[window_start...window_end].join("\n")
  result = RubySyntax.analyze(source)
  return [nil, nil, window_start, window_end] unless result

  offsets = []
  off = 0
  i = window_start
  while i < window_end
    offsets.push(off)
    off += lines[i].bytesize + 1
    i += 1
  end
  [result, [result.highlight_map, offsets, window_start], window_start, window_end]
end

# Initial syntax analysis around the top of the file
if highlight_enabled
  _result, syntax, window_start, window_end = analyze_window(buffer, 0, EDIT_ROWS - 1)
end

# -- Drawing helpers --

def draw_status(console, filepath, buffer, scroll_top, message)
  line_num = buffer.cursor_y + 1
  col_num = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x) + 1
  modified = buffer.changed ? " [+]" : ""
  name = filepath || "[untitled]"
  status = " #{name}#{modified}  #{line_num}:#{col_num}"

  if message
    status = " #{message}"
  end

  # Pad to full width
  padding = Console::COLS - Editor.display_width(status)
  status += " " * padding if padding > 0

  console.put_string_at(0, STATUS_ROW, Editor.display_slice(status, 0, Console::COLS), STATUS_ATTR)
end

# The command bar is redrawn every frame to recover from ring buffer scrolls,
# but its content only changes with the IME mode label, so the composed string
# is cached per label (a small fixed set) instead of rebuilding the padding
# and scanning display widths on every keystroke.
COMMAND_BAR_CACHE = {}

def draw_command_bar(console)
  mode = $ime ? $ime.mode_label : nil
  bar = COMMAND_BAR_CACHE[mode]
  unless bar
    bar = " Ctrl-S:Save  Ctrl-Q:Quit  Ctrl-Z:Undo  Ctrl-Y:Redo"
    if mode
      padding = Console::COLS - Editor.display_width(bar) - Editor.display_width(mode)
      bar += " " * padding if padding > 0
      bar += mode
    else
      padding = Console::COLS - Editor.display_width(bar)
      bar += " " * padding if padding > 0
    end
    bar = Editor.display_slice(bar, 0, Console::COLS)
    COMMAND_BAR_CACHE[mode] = bar
  end
  console.put_string_at(0, COMMAND_ROW, bar, COMMAND_ATTR)
end

# Prompt for text input on the command bar row.
# Returns the entered string, or nil if cancelled with Escape.
# When y_or_n: true, returns immediately on a single character input.
def prompt_input(console, keyboard, label, y_or_n: false)
  input = ""
  loop do
    # Draw prompt
    display = " #{label}#{input}"
    padding = Console::COLS - Editor.display_width(display)
    display += " " * padding if padding > 0
    console.put_string_at(0, COMMAND_ROW, Editor.display_slice(display, 0, Console::COLS), COMMAND_ATTR)
    console.commit

    c = keyboard.read_char
    unless c
      DVI.wait_vsync
      next
    end

    case c
    when Keyboard::ENTER
      return input
    when Keyboard::ESCAPE
      return nil
    when Keyboard::BSPACE
      if input.bytesize > 0
        input = input.byteslice(0, Editor.prev_char_byte_pos(input, input.bytesize))
      end
    else
      if c.printable?
        ch = c.to_s
        if y_or_n
          return ch if ch == "y" || ch == "Y" || ch == "n" || ch == "N"
        else
          input += ch
        end
      end
    end
  end
end

# Draw one visible line. The syntax bundle is [highlight_map, window_offsets,
# window_start]; a line inside the parsed window is highlighted, otherwise it
# is drawn as plain text.
def draw_line(console, buffer, screen_row, scroll_top, scroll_left, syntax)
  row = EDIT_TOP + screen_row
  line_index = scroll_top + screen_row
  console.clear_line(row)
  return if line_index >= buffer.lines.length

  line = buffer.lines[line_index]
  line_offset = nil
  if syntax
    rel = line_index - syntax[2]
    line_offset = syntax[1][rel] if rel >= 0 && rel < syntax[1].length
  end
  if line_offset
    RubySyntax.draw_line(0, row, line, syntax[0], line_offset, scroll_left, Console::COLS, EDIT_ATTR)
  else
    text = Editor.display_slice(line, scroll_left, Console::COLS)
    console.put_string_at(0, row, text, EDIT_ATTR) if text && text.bytesize > 0
  end
end

def draw_all_lines(console, buffer, scroll_top, scroll_left, syntax)
  i = 0
  while i < EDIT_ROWS
    draw_line(console, buffer, i, scroll_top, scroll_left, syntax)
    i += 1
  end
end

# Differential vertical scroll: shift the visible region by vdelta rows using
# the DVI ring-buffer scroll (O(1)), then draw only the newly exposed lines.
# vdelta > 0 scrolls content up (cursor moved down); vdelta < 0 scrolls down.
# The status/command rows shifted by the global ring scroll are restored by
# the unconditional draw_status/draw_command_bar later in the same frame.
def scroll_view(console, buffer, scroll_top, scroll_left, vdelta, syntax)
  if vdelta > 0
    DVI::Text.scroll_up(vdelta, EDIT_ATTR)
    row = EDIT_ROWS - vdelta
    while row < EDIT_ROWS
      draw_line(console, buffer, row, scroll_top, scroll_left, syntax)
      row += 1
    end
  else
    n = -vdelta
    DVI::Text.scroll_down(n, EDIT_ATTR)
    row = 0
    while row < n
      draw_line(console, buffer, row, scroll_top, scroll_left, syntax)
      row += 1
    end
  end
end

# Redraw the visible region after a horizontal scroll. Horizontal scroll has no
# ring-buffer shortcut, so every visible line whose content moved must be
# redrawn. Lines whose full display width is left of both the old and the new
# viewport are blank before and after, so they are skipped.
def draw_hscroll(console, buffer, scroll_top, old_scroll_left, scroll_left, syntax)
  threshold = old_scroll_left < scroll_left ? old_scroll_left : scroll_left
  i = 0
  while i < EDIT_ROWS
    line = buffer.lines[scroll_top + i]
    # bytesize is a cheap upper bound of display width, checked first so short
    # lines skip the O(n) width scan.
    if line.nil? || line.bytesize <= threshold || Editor.display_width(line) <= threshold
      i += 1
      next
    end
    draw_line(console, buffer, i, scroll_top, scroll_left, syntax)
    i += 1
  end
end

# Returns the highlight map bytes covering the line at line_index, or nil
# when the line is outside the parsed window.
def highlight_slice(syntax, line_index, line)
  return nil unless syntax
  rel = line_index - syntax[2]
  offsets = syntax[1]
  return nil if rel < 0 || rel >= offsets.length
  syntax[0].byteslice(offsets[rel], line.bytesize)
end

# Redraw the visible lines whose highlight changed between two parsed
# windows (after a window rebuild). Lines whose highlight bytes are
# identical render the same and are skipped, so a rebuild for pure
# scrolling usually redraws nothing, while an edit that recolors following
# lines (e.g. an opened string literal) updates exactly those lines.
# Rows outside [first_row, last_row) and skip_row are drawn elsewhere in
# the same frame. Returns true if any line was drawn.
def sync_highlight_changes(console, buffer, scroll_top, scroll_left, first_row, last_row, skip_row, old_syntax, syntax)
  drawn = false
  row = first_row
  while row < last_row
    if row != skip_row
      line_index = scroll_top + row
      line = buffer.lines[line_index]
      if line && highlight_slice(old_syntax, line_index, line) != highlight_slice(syntax, line_index, line)
        draw_line(console, buffer, row, scroll_top, scroll_left, syntax)
        drawn = true
      end
    end
    row += 1
  end
  drawn
end

# -- Viewport scrolling --

def adjust_vertical_scroll(buffer, scroll_top)
  if buffer.cursor_y < scroll_top
    return buffer.cursor_y
  end
  if buffer.cursor_y >= scroll_top + EDIT_ROWS
    return buffer.cursor_y - EDIT_ROWS + 1
  end
  scroll_top
end

def adjust_horizontal_scroll(buffer, scroll_left)
  line = buffer.current_line
  # Display width never exceeds bytesize (a character is at least as many
  # bytes as columns), so typical short lines skip the O(n) width scan that
  # would otherwise run on every keystroke.
  return 0 if line.bytesize <= COLS
  line_width = Editor.display_width(line)
  # Current line fits on screen: reset scroll
  return 0 if line_width <= COLS
  cursor_col = Editor.byte_to_display_col(line, buffer.cursor_x)
  # Cursor still inside the visible window: no scroll. Horizontal scroll cannot
  # use the ring buffer, so every step forces a full-width redraw; keeping the
  # cursor inside the window avoids redrawing on each column of movement.
  if cursor_col >= scroll_left && cursor_col < scroll_left + COLS
    return scroll_left
  end
  # Cursor left the window: jump-scroll to roughly center the cursor so the next
  # redraw is deferred for about half a screen of further movement.
  new_scroll = cursor_col - COLS / 2
  max_scroll = line_width - COLS + 1
  new_scroll = max_scroll if new_scroll > max_scroll
  new_scroll = 0 if new_scroll < 0
  new_scroll
end

# -- Initial draw --
console.clear
draw_command_bar(console)
draw_all_lines(console, buffer, scroll_top, scroll_left, syntax)
draw_status(console, filepath, buffer, scroll_top, nil)

# Position cursor
screen_col = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x) - scroll_left
screen_row = EDIT_TOP + buffer.cursor_y - scroll_top
console.move_to(screen_col, screen_row)
console.show_cursor
console.commit

# -- Main loop --
while running
  c = keyboard.read_char
  unless c
    DVI.wait_vsync
    next
  end

  console.hide_cursor
  message = nil
  old_dirty = buffer.dirty
  old_scroll_top = scroll_top
  old_scroll_left = scroll_left
  buffer.clear_dirty

  # Process through input method if active
  ime_handled = false
  if $ime
    ime_result = $ime.process(c)
    case ime_result
    when :commit
      text = $ime.take_committed
      redo_stack.clear
      undo_record(undo_stack, [:insert, buffer.cursor_y, buffer.cursor_x, text])
      buffer.put(text)
      ime_handled = true
    when :consumed
      buffer.mark_dirty(:content)
      ime_handled = true
    end
    # :passthrough falls through to normal handling
  end

  unless ime_handled
  case c
  when Keyboard::CTRL_Q
    if buffer.changed
      answer = prompt_input(console, keyboard, "Unsaved changes. Quit? (y/n): ", y_or_n: true)
      draw_command_bar(console)
      buffer.mark_dirty(:structure)
      unless answer && (answer == "y" || answer == "Y")
        message = "Quit cancelled"
        next
      end
    end
    running = false
    next
  when Keyboard::CTRL_S
    unless filepath
      filepath = prompt_input(console, keyboard, "Save as: ")
      draw_command_bar(console)
      unless filepath && filepath.bytesize > 0
        filepath = nil
        message = "Save cancelled"
        buffer.mark_dirty(:structure)
        next
      end
    end
    begin
      File.open(filepath, "w") do |f|
        f.write(buffer.lines.join("\n") + "\n")
      end
      buffer.changed = false
      message = "Saved #{filepath}"
    rescue => e
      message = "Save failed: #{e.message}"
    end
  when Keyboard::CTRL_Z
    if perform_undo(buffer, undo_stack, redo_stack)
      message = "Undo"
    end
  when Keyboard::CTRL_Y
    if perform_redo(buffer, undo_stack, redo_stack)
      message = "Redo"
    end
  when Keyboard::PAGEUP
    scroll_top -= EDIT_ROWS
    scroll_top = 0 if scroll_top < 0
    new_y = scroll_top
    buffer.move_to(buffer.cursor_x, new_y)
  when Keyboard::PAGEDOWN
    max_scroll = buffer.lines.length - EDIT_ROWS
    max_scroll = 0 if max_scroll < 0
    scroll_top += EDIT_ROWS
    scroll_top = max_scroll if scroll_top > max_scroll
    new_y = scroll_top + EDIT_ROWS - 1
    new_y = buffer.lines.length - 1 if new_y >= buffer.lines.length
    buffer.move_to(buffer.cursor_x, new_y)
  when Keyboard::HOME
    undo_record_break(undo_stack)
    buffer.head
  when Keyboard::END_KEY
    undo_record_break(undo_stack)
    buffer.tail
  when Keyboard::DELETE
    redo_stack.clear
    undo_record_break(undo_stack)
    if buffer.cursor_x >= buffer.current_line.bytesize && buffer.cursor_y + 1 < buffer.lines.length
      undo_record(undo_stack, [:join, buffer.cursor_y, buffer.cursor_x])
      buffer.lines[buffer.cursor_y] = buffer.current_line + buffer.lines[buffer.cursor_y + 1]
      buffer.lines.delete_at(buffer.cursor_y + 1)
      buffer.changed = true
      buffer.mark_dirty(:structure)
    else
      if buffer.cursor_x < buffer.current_line.bytesize
        deleted = Editor.char_at_bytepos(buffer.current_line, buffer.cursor_x)
        undo_record(undo_stack, [:delete, buffer.cursor_y, buffer.cursor_x, deleted])
      end
      buffer.delete
      buffer.mark_dirty(:content)
    end
  when Keyboard::ENTER
    redo_stack.clear
    undo_record(undo_stack, [:split, buffer.cursor_y, buffer.cursor_x])
    undo_record_break(undo_stack)
    buffer.put(c.to_buffer_input)
    # Auto-indent: re-analyze the window around the cursor to get correct
    # indent. No margin below the cursor: indentation only depends on the
    # lines above.
    if highlight_enabled
      result, _syntax, indent_window_start, _window_end = analyze_window(buffer, buffer.cursor_y - 1, buffer.cursor_y, 0)
      if result
        # Re-indent previous line (e.g. de-indent end/else/ensure)
        prev_y = buffer.cursor_y - 1
        if prev_y >= 0
          old_line = buffer.lines[prev_y]
          if RubySyntax.reindent_line(buffer, prev_y, result.indent_level(prev_y - indent_window_start))
            undo_record(undo_stack, [:replace_line, prev_y, old_line])
          end
        end
        # Indent new line
        level = result.indent_level(buffer.cursor_y - indent_window_start)
        if level > 0
          spaces = "  " * level
          undo_record(undo_stack, [:insert, buffer.cursor_y, 0, spaces])
          buffer.put(spaces)
        end
      end
    end
  when Keyboard::BSPACE
    redo_stack.clear
    if buffer.cursor_x > 0
      prev_pos = Editor.prev_char_byte_pos(buffer.current_line, buffer.cursor_x)
      deleted = buffer.current_line.byteslice(prev_pos, buffer.cursor_x - prev_pos)
      undo_record(undo_stack, [:delete, buffer.cursor_y, prev_pos, deleted])
    elsif buffer.cursor_y > 0
      undo_record_break(undo_stack)
      undo_record(undo_stack, [:join, buffer.cursor_y - 1, buffer.lines[buffer.cursor_y - 1].bytesize])
    end
    buffer.put(c.to_buffer_input)
  when Keyboard::UP, Keyboard::DOWN, Keyboard::LEFT, Keyboard::RIGHT
    undo_record_break(undo_stack)
    buffer.put(c.to_buffer_input)
  when Keyboard::ESCAPE
    # Ignore
  else
    if c.printable?
      redo_stack.clear
      undo_record(undo_stack, [:insert, buffer.cursor_y, buffer.cursor_x, c.to_s])
      buffer.put(c.to_s)
      # De-indent on space after keywords like when, elsif, rescue, in
      if highlight_enabled && c.to_s == " " && RubySyntax.should_dedent_on_space?(buffer.current_line)
        result, _syntax, indent_window_start, _window_end = analyze_window(buffer, buffer.cursor_y, buffer.cursor_y, 0)
        if result
          old_line = buffer.current_line
          if RubySyntax.reindent_line(buffer, buffer.cursor_y, result.indent_level(buffer.cursor_y - indent_window_start))
            undo_record(undo_stack, [:replace_line, buffer.cursor_y, old_line])
            buffer.mark_dirty(:content)
          end
        end
      end
    else
      input = c.to_buffer_input
      buffer.put(input) if input
    end
  end
  end # unless ime_handled

  # Adjust scroll for cursor visibility. Scrolling is a viewport change, not a
  # buffer change, so it does not mark the buffer dirty (and does not trigger a
  # syntax re-analysis); it is handled by the differential redraw below.
  scroll_top = adjust_vertical_scroll(buffer, scroll_top)
  scroll_left = adjust_horizontal_scroll(buffer, scroll_left)

  # Redraw based on dirty level and viewport movement. content_changed is
  # taken before the old_dirty carry-over: a carried value was already
  # analyzed last frame and the buffer has not changed since, so the carry
  # only affects the redraw choice below, not the re-analysis.
  dirty = buffer.dirty
  content_changed = dirty == :content || dirty == :structure
  dirty = old_dirty if dirty == :none && old_dirty != :none
  vdelta = scroll_top - old_scroll_top
  hscrolled = scroll_left != old_scroll_left

  # Rebuild the parsed window on content changes, or when the viewport scrolls
  # out of the cached window. Within the window the highlight map stays valid, so
  # pure scrolling reuses it and only newly exposed lines are redrawn.
  window_rebuilt = false
  if highlight_enabled
    vis_bottom = scroll_top + EDIT_ROWS
    vis_bottom = buffer.lines.length if vis_bottom > buffer.lines.length
    if content_changed || scroll_top < window_start || vis_bottom > window_end
      old_syntax = syntax
      _result, syntax, window_start, window_end = analyze_window(buffer, scroll_top, scroll_top + EDIT_ROWS - 1)
      window_rebuilt = true
    end
  end

  if dirty == :structure || vdelta.abs >= EDIT_ROWS || (hscrolled && vdelta != 0)
    draw_all_lines(console, buffer, scroll_top, scroll_left, syntax)
  elsif hscrolled
    # A rebuild here only happens for content edits, and draw_hscroll already
    # redraws every line that can be visible in either viewport.
    draw_hscroll(console, buffer, scroll_top, old_scroll_left, scroll_left, syntax)
  else
    cursor_row = dirty == :content ? buffer.cursor_y - scroll_top : -1
    if vdelta != 0
      scroll_view(console, buffer, scroll_top, scroll_left, vdelta, syntax)
    end
    # After a rebuild, redraw exactly the lines whose highlight bytes changed.
    # Rows exposed by scroll_view and the cursor row are drawn separately.
    if window_rebuilt
      first_row = vdelta < 0 ? -vdelta : 0
      last_row = vdelta > 0 ? EDIT_ROWS - vdelta : EDIT_ROWS
      sync_highlight_changes(console, buffer, scroll_top, scroll_left, first_row, last_row, cursor_row, old_syntax, syntax)
    end
    if cursor_row >= 0
      draw_line(console, buffer, cursor_row, scroll_top, scroll_left, syntax)
    end
  end

  draw_status(console, filepath, buffer, scroll_top, message)

  # Draw preedit overlay if IME has uncommitted text
  preedit_width = 0
  if $ime && $ime.preedit.bytesize > 0
    cursor_col = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x) - scroll_left
    preedit_row = EDIT_TOP + buffer.cursor_y - scroll_top
    if preedit_row >= EDIT_TOP && preedit_row <= EDIT_BOTTOM
      max_preedit = COLS - cursor_col
      if max_preedit > 0
        visible = Editor.display_slice($ime.preedit, 0, max_preedit)
        if visible && visible.bytesize > 0
          DVI::Text.put_string(cursor_col, preedit_row, visible, InputMethod::PREEDIT_ATTR)
          preedit_width = Editor.display_width(visible)
        end
      end
    end
  end

  # Draw candidate list on command bar if available, otherwise redraw command bar for mode label
  if $ime && $ime.candidates
    cand_text = ""
    $ime.candidates.each_with_index do |c, ci|
      break if ci >= 7
      cand_text += " " if ci > 0
      cand_text += "#{ci + 1}:#{c}"
    end
    mode = $ime.mode_label
    if mode
      padding = Console::COLS - Editor.display_width(cand_text) - Editor.display_width(mode)
      cand_text += " " * padding if padding > 0
      cand_text += mode
    else
      padding = Console::COLS - Editor.display_width(cand_text)
      cand_text += " " * padding if padding > 0
    end
    console.put_string_at(0, COMMAND_ROW, Editor.display_slice(cand_text, 0, Console::COLS), COMMAND_ATTR)
  else
    draw_command_bar(console)
  end

  # Position cursor (after preedit if present)
  screen_col = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x) - scroll_left + preedit_width
  screen_row = EDIT_TOP + buffer.cursor_y - scroll_top
  console.move_to(screen_col, screen_row)
  console.show_cursor
  console.commit
end

# Cleanup
console.hide_cursor
console.clear
console.commit
