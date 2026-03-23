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

def draw_command_bar(console)
  bar = " Ctrl-S:Save  Ctrl-Q:Quit  Ctrl-Z:Undo  Ctrl-Y:Redo"
  padding = Console::COLS - Editor.display_width(bar)
  bar += " " * padding if padding > 0
  console.put_string_at(0, COMMAND_ROW, Editor.display_slice(bar, 0, Console::COLS), COMMAND_ATTR)
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
    when :ENTER
      return input
    when :ESCAPE
      return nil
    when :BSPACE
      if input.bytesize > 0
        input = input.byteslice(0, Editor.prev_char_byte_pos(input, input.bytesize))
      end
    when String
      if y_or_n
        return c if c == "y" || c == "Y" || c == "n" || c == "N"
      else
        input += c
      end
    end
  end
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
  when 19 # Ctrl-S
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
  when 26 # Ctrl-Z
    if perform_undo(buffer, undo_stack, redo_stack)
      message = "Undo"
    end
  when 25 # Ctrl-Y
    if perform_redo(buffer, undo_stack, redo_stack)
      message = "Redo"
    end
  when :HOME
    undo_record_break(undo_stack)
    buffer.head
  when :END
    undo_record_break(undo_stack)
    buffer.tail
  when :DELETE
    redo_stack.clear
    undo_record_break(undo_stack)
    if buffer.cursor_x >= buffer.current_line.bytesize && buffer.cursor_y + 1 < buffer.lines.length
      # At end of line: join with next line
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
  when Integer
    # Ignore other control codes
  else
    # String or Symbol: pass to buffer
    case c
    when String
      redo_stack.clear
      undo_record(undo_stack, [:insert, buffer.cursor_y, buffer.cursor_x, c])
      buffer.put(c)
    when :ENTER
      redo_stack.clear
      undo_record(undo_stack, [:split, buffer.cursor_y, buffer.cursor_x])
      undo_record_break(undo_stack)
      buffer.put(c)
    when :BSPACE
      redo_stack.clear
      if buffer.cursor_x > 0
        prev_pos = Editor.prev_char_byte_pos(buffer.current_line, buffer.cursor_x)
        deleted = buffer.current_line.byteslice(prev_pos, buffer.cursor_x - prev_pos)
        undo_record(undo_stack, [:delete, buffer.cursor_y, prev_pos, deleted])
      elsif buffer.cursor_y > 0
        undo_record_break(undo_stack)
        undo_record(undo_stack, [:join, buffer.cursor_y - 1, buffer.lines[buffer.cursor_y - 1].bytesize])
      end
      buffer.put(c)
    when :UP, :DOWN, :LEFT, :RIGHT
      undo_record_break(undo_stack)
      buffer.put(c)
    else
      buffer.put(c)
    end
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
