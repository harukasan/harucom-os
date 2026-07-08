# RubySyntax drawing helpers for DVI text mode.
#
# Provides a shared draw_line method used by both the editor (edit.rb)
# and the IRB line editor (line_editor.rb) to render syntax-highlighted
# Ruby source lines.
#
# Color theme: Monokai-inspired (ANSI-ordered RGB332 palette).

module RubySyntax
  # Category -> DVI attribute byte (fg palette index << 4 | bg=0)
  CATEGORY_ATTRS = [
    0xF0, # 0: default    -> palette 15 (white)
    0xD0, # 1: keyword    -> palette 13 (pink)
    0xA0, # 2: string     -> palette 10 (lime)
    0x80, # 3: comment    -> palette 8  (dark gray)
    0x90, # 4: number     -> palette 9  (orange)
    0x90, # 5: symbol     -> palette 9  (orange)
    0xC0, # 6: constant   -> palette 12 (sky blue)
    0x60, # 7: variable   -> palette 6  (cyan)
    0xE0, # 8: method     -> palette 14 (bright cyan)
  ].freeze

  # Category -> bold flag
  CATEGORY_BOLD = [
    false, # 0: default
    true,  # 1: keyword
    false, # 2: string
    false, # 3: comment
    false, # 4: number
    false, # 5: symbol
    false, # 6: constant
    false, # 7: variable
    false, # 8: method
  ].freeze

  # Keywords that trigger de-indent when followed by a space.
  DEDENT_ON_SPACE = ["when ", "elsif ", "rescue ", "in "]

  # Re-indent a line in the buffer to match the given indent level.
  # Returns true if the line was modified.
  def self.reindent_line(buffer, line_index, level)
    line = buffer.lines[line_index]
    return false unless line
    current_spaces = 0
    while current_spaces < line.bytesize && line.getbyte(current_spaces) == 0x20
      current_spaces += 1
    end
    desired = "  " * level
    return false if current_spaces == desired.bytesize
    buffer.lines[line_index] = desired + line.byteslice(current_spaces, 65535).to_s
    # Adjust cursor if on this line
    if buffer.cursor_y == line_index
      delta = desired.bytesize - current_spaces
      new_x = buffer.cursor_x + delta
      buffer.move_to(new_x < 0 ? 0 : new_x, line_index)
    end
    true
  end

  # Check if a line ends with a keyword that should trigger de-indent
  # when space is pressed.
  def self.should_dedent_on_space?(line)
    DEDENT_ON_SPACE.each do |kw|
      stripped = line.lstrip
      return true if stripped == kw
    end
    false
  end

  # Draw a single line with syntax highlighting.
  #
  # col_start:     screen column to start drawing
  # row:           screen row
  # line:          source line string
  # highlight_map: byte string from RubySyntax.analyze(source).highlight_map (or nil)
  # line_offset:   byte offset of this line within the full source
  # scroll:        horizontal scroll offset (display columns)
  # max_width:     maximum display columns to render
  # default_attr:  attribute byte for unhighlighted text
  #
  # This runs for every highlighted line on every redraw, so the loop avoids
  # per-character work: spans of equal attribute are tracked as byte ranges
  # and emitted with a single byteslice, and the UTF-8 character length is
  # derived from the lead byte inline instead of through method calls.
  def self.draw_line(col_start, row, line, highlight_map, line_offset, scroll, max_width, default_attr)
    return unless line

    start_byte = scroll > 0 ? Editor.display_col_to_byte(line, scroll) : 0
    line_size = line.bytesize
    map_size = highlight_map ? highlight_map.bytesize : 0
    col = col_start
    pos = start_byte
    span_col = col       # screen column where the current span starts
    span_byte = pos      # byte offset where the current span starts
    span_attr = default_attr
    span_bold = false

    while pos < line_size && (col - col_start) < max_width
      lead = line.getbyte(pos)
      clen = lead < 0x80 ? 1 : (lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4))
      cw = clen > 1 ? 2 : 1
      break if (col - col_start) + cw > max_width

      cat = 0
      src_offset = line_offset + pos
      cat = highlight_map.getbyte(src_offset) if src_offset < map_size
      attr = CATEGORY_ATTRS[cat] || default_attr
      bold = CATEGORY_BOLD[cat] || false

      if attr != span_attr || bold != span_bold
        if pos > span_byte
          text = line.byteslice(span_byte, pos - span_byte).to_s
          if span_bold
            DVI::Text.put_string_bold(span_col, row, text, span_attr)
          else
            DVI::Text.put_string(span_col, row, text, span_attr)
          end
          span_col = col
          span_byte = pos
        end
        span_attr = attr
        span_bold = bold
      end

      col += cw
      pos += clen
    end

    if pos > span_byte
      text = line.byteslice(span_byte, pos - span_byte).to_s
      if span_bold
        DVI::Text.put_string_bold(span_col, row, text, span_attr)
      else
        DVI::Text.put_string(span_col, row, text, span_attr)
      end
    end
  end
end
