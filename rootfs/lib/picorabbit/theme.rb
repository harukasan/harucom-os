module PicoRabbit
  class Theme
    G = DVI::Graphics

    def render_slide(p5, slide, slide_index, total_slides)
      render_background(p5)
      y = render_title(p5, slide.title)
      slide.elements.each do |element|
        y = render_element(p5, element, margin_x, y)
      end
      render_footer(p5, slide_index, total_slides)
    end

    # Override these in subclasses

    def render_background(p5)
      p5.background(background_color)
    end

    def render_title(p5, title)
      return body_y unless title
      p5.text_font(title_font)
      p5.text_color(title_color)
      p5.text_align(:left)
      p5.text(title, margin_x, title_y)
      # Separator line
      sep_y = title_y + title_font_height + 4
      p5.stroke(separator_color)
      p5.line(margin_x, sep_y, 640 - margin_x, sep_y)
      p5.no_stroke
      sep_y + 12
    end

    def render_element(p5, element, x, y)
      case element.type
      when :text
        p5.text_font(body_font)
        p5.text_color(text_color)
        p5.text(element.text, x, y)
        y + body_font_height + leading
      when :bullet
        p5.text_font(body_font)
        p5.text_color(text_color)
        indent = x + element.level * bullet_indent
        p5.text(bullet_char, indent, y)
        p5.text(element.text, indent + bullet_width, y)
        y + body_font_height + leading
      when :code_block
        render_code_block(p5, element.text, x, y)
      when :blank
        y + body_font_height / 2
      else
        y
      end
    end

    def render_code_block(p5, lines, x, y)
      padding = 6
      line_height = code_font_height + 2
      block_height = lines.length * line_height + padding * 2
      p5.fill(code_background_color)
      p5.no_stroke
      p5.rect(x, y, content_width, block_height)
      p5.no_fill
      p5.text_font(code_font)
      p5.text_color(code_text_color)
      ty = y + padding
      lines.each do |line|
        p5.text(line, x + padding, ty)
        ty += line_height
      end
      y + block_height + leading
    end

    def render_footer(p5, slide_index, total_slides)
      p5.text_font(footer_font)
      p5.text_color(footer_color)
      p5.text_align(:right)
      p5.text("#{slide_index + 1} / #{total_slides}", 640 - margin_x, 480 - margin_y - footer_font_height)
      p5.text_align(:left)
    end

    # Layout constants (override in subclasses)

    def margin_x; 40; end
    def margin_y; 20; end
    def title_y; 40; end
    def body_y; 100; end
    def content_width; 560; end
    def leading; 4; end
    def bullet_indent; 20; end
    def bullet_char; "-"; end
    def bullet_width; 16; end

    # Font accessors (override in subclasses)

    def title_font; G::FONT_HELVETICA_BOLD_24; end
    def title_font_height; G.font_height(title_font); end
    def body_font; G::FONT_HELVETICA_14; end
    def body_font_height; G.font_height(body_font); end
    def code_font; G::FONT_SPLEEN_8X16; end
    def code_font_height; G.font_height(code_font); end
    def footer_font; G::FONT_FIXED_5X7; end
    def footer_font_height; G.font_height(footer_font); end

    # Color accessors (override in subclasses)

    def background_color; 0xFF; end
    def title_color; 0x00; end
    def text_color; 0x00; end
    def separator_color; 0x49; end
    def code_background_color; 0x49; end
    def code_text_color; 0xFF; end
    def footer_color; 0x49; end
  end
end
