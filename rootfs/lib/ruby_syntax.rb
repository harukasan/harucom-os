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
  def self.draw_line(col_start, row, line, highlight_map, line_offset, scroll, max_width, default_attr)
    return unless line

    start_byte = scroll > 0 ? Editor.display_col_to_byte(line, scroll) : 0
    col = col_start
    pos = start_byte
    span_start = col
    span_text = ""
    span_attr = default_attr
    span_bold = false

    while pos < line.bytesize && (col - col_start) < max_width
      clen = Editor.char_bytesize_at(line, pos)
      cw = clen > 1 ? 2 : 1
      break if (col - col_start) + cw > max_width

      cat = 0
      if highlight_map
        src_offset = line_offset + pos
        if src_offset < highlight_map.bytesize
          cat = highlight_map.getbyte(src_offset)
        end
      end
      attr = CATEGORY_ATTRS[cat] || default_attr
      bold = CATEGORY_BOLD[cat] || false

      if (attr != span_attr || bold != span_bold) && span_text.bytesize > 0
        if span_bold
          DVI::Text.put_string_bold(span_start, row, span_text, span_attr)
        else
          DVI::Text.put_string(span_start, row, span_text, span_attr)
        end
        span_start = col
        span_text = ""
        span_attr = attr
        span_bold = bold
      elsif span_text.bytesize == 0
        span_attr = attr
        span_bold = bold
      end

      span_text += line.byteslice(pos, clen).to_s
      col += cw
      pos += clen
    end

    if span_text.bytesize > 0
      if span_bold
        DVI::Text.put_string_bold(span_start, row, span_text, span_attr)
      else
        DVI::Text.put_string(span_start, row, span_text, span_attr)
      end
    end
  end
end
