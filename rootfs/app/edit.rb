# edit: Full-screen text editor
#
# Usage from IRB:
#   edit /path/to/file.rb
#
# Keybindings:
#   Ctrl-S: Save
#   Ctrl-Q: Quit
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
filepath = ARGV[0] || "/untitled.rb"
scroll_top = 0
scroll_left = 0
running = true
message = nil

# Load file
if File.exist?(filepath)
  content = File.open(filepath, "r") { |f| f.read }
  if content
    lines = content.split("\n")
    buffer.lines.clear
    lines.each { |l| buffer.lines.push(l) }
    buffer.lines.push("") if buffer.lines.empty?
  end
  buffer.changed = false
end

# -- Drawing helpers --

def draw_status(console, filepath, buffer, scroll_top, message)
  line_num = buffer.cursor_y + 1
  col_num = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x) + 1
  modified = buffer.changed ? " [+]" : ""
  status = " #{filepath}#{modified}  #{line_num}:#{col_num}"

  if message
    status = " #{message}"
  end

  # Pad to full width
  padding = Console::COLS - Editor.display_width(status)
  status += " " * padding if padding > 0

  console.put_string_at(0, STATUS_ROW, Editor.display_slice(status, 0, Console::COLS), STATUS_ATTR)
end

def draw_command_bar(console)
  bar = " Ctrl-S:Save  Ctrl-Q:Quit"
  padding = Console::COLS - Editor.display_width(bar)
  bar += " " * padding if padding > 0
  console.put_string_at(0, COMMAND_ROW, Editor.display_slice(bar, 0, Console::COLS), COMMAND_ATTR)
end

def draw_line(console, buffer, screen_row, scroll_top, scroll_left)
  row = EDIT_TOP + screen_row
  line_index = scroll_top + screen_row
  if line_index < buffer.lines.length
    text = Editor.display_slice(buffer.lines[line_index], scroll_left, Console::COLS)
    console.clear_line(row)
    console.put_string_at(0, row, text, EDIT_ATTR) if text && text.bytesize > 0
  else
    console.clear_line(row)
  end
end

def draw_all_lines(console, buffer, scroll_top, scroll_left)
  i = 0
  while i < EDIT_ROWS
    draw_line(console, buffer, i, scroll_top, scroll_left)
    i += 1
  end
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
  line_width = Editor.display_width(buffer.current_line)
  # Current line fits on screen: reset scroll
  if line_width <= COLS
    return 0
  end
  cursor_col = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x)
  # Cursor left of viewport
  if cursor_col < scroll_left
    return cursor_col
  end
  # Cursor right of viewport
  if cursor_col >= scroll_left + COLS
    return cursor_col - COLS + 1
  end
  scroll_left
end

# -- Initial draw --
console.clear
draw_command_bar(console)
draw_all_lines(console, buffer, scroll_top, scroll_left)
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
  buffer.clear_dirty

  case c
  when 17 # Ctrl-Q
    running = false
    next
  when 19 # Ctrl-S
    File.open(filepath, "w") do |f|
      buffer.lines.each_with_index do |line, i|
        f.puts(line)
      end
    end
    buffer.changed = false
    message = "Saved #{filepath}"
  when :PAGEUP
    scroll_top -= EDIT_ROWS
    scroll_top = 0 if scroll_top < 0
    new_y = scroll_top
    buffer.move_to(buffer.cursor_x, new_y)
    buffer.mark_dirty(:structure)
  when :PAGEDOWN
    max_scroll = buffer.lines.length - EDIT_ROWS
    max_scroll = 0 if max_scroll < 0
    scroll_top += EDIT_ROWS
    scroll_top = max_scroll if scroll_top > max_scroll
    new_y = scroll_top + EDIT_ROWS - 1
    new_y = buffer.lines.length - 1 if new_y >= buffer.lines.length
    buffer.move_to(buffer.cursor_x, new_y)
    buffer.mark_dirty(:structure)
  when :HOME
    buffer.head
  when :END
    buffer.tail
  when :DELETE
    if buffer.cursor_x >= buffer.current_line.bytesize && buffer.cursor_y + 1 < buffer.lines.length
      # At end of line: join with next line
      buffer.lines[buffer.cursor_y] = buffer.current_line + buffer.lines[buffer.cursor_y + 1]
      buffer.lines.delete_at(buffer.cursor_y + 1)
      buffer.changed = true
      buffer.mark_dirty(:structure)
    else
      buffer.delete
      buffer.mark_dirty(:content)
    end
  when Integer
    # Ignore other control codes
  else
    # String or Symbol: pass to buffer
    buffer.put(c)
  end

  # Adjust scroll for cursor visibility
  new_vscroll = adjust_vertical_scroll(buffer, scroll_top)
  if new_vscroll != scroll_top
    scroll_top = new_vscroll
    buffer.mark_dirty(:structure)
  end

  new_hscroll = adjust_horizontal_scroll(buffer, scroll_left)
  if new_hscroll != scroll_left
    scroll_left = new_hscroll
    buffer.mark_dirty(:structure)
  end

  # Redraw based on dirty level
  dirty = buffer.dirty
  dirty = old_dirty if dirty == :none && old_dirty != :none

  case dirty
  when :structure
    draw_all_lines(console, buffer, scroll_top, scroll_left)
  when :content
    screen_row = buffer.cursor_y - scroll_top
    draw_line(console, buffer, screen_row, scroll_top, scroll_left)
  end

  draw_status(console, filepath, buffer, scroll_top, message)

  # Position cursor
  screen_col = Editor.byte_to_display_col(buffer.current_line, buffer.cursor_x) - scroll_left
  screen_row = EDIT_TOP + buffer.cursor_y - scroll_top
  console.move_to(screen_col, screen_row)
  console.show_cursor
  console.commit
end

# Cleanup
console.hide_cursor
console.clear
console.commit
