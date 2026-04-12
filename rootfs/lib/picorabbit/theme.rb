module PicoRabbit
  class Theme
    G = DVI::Graphics

    def initialize
      @image_cache = {}
      @numbered_counter = 0
    end

    def render_slide(p5, slide, slide_index, total_slides, step = nil, metadata = {})
      if @last_slide_index != slide_index || @last_step != step
        @last_slide_index = slide_index
        @last_step = step
        @p5_last_code = nil
      end
      render_background(p5)
      if slide.title_slide
        render_title_slide(p5, slide, metadata)
      else
        y = render_title(p5, slide.title)
        wait_count = 0
        @numbered_counter = 0
        slide.elements.each do |element|
          if element.type == :wait
            wait_count += 1
            break if step && wait_count > step
          else
            @numbered_counter = 0 unless element.type == :numbered
            y = render_element(p5, element, margin_x, y)
          end
        end
      end
      render_footer(p5, slide_index, total_slides)
    end

    def render_title_slide(p5, slide, metadata)
      # Title centered vertically (supports multi-line via \n)
      p5.text_font(title_font)
      p5.text_color(title_color)
      p5.text_align(:center)
      title_lines = slide.title.split("\n")
      ty = 180
      title_lines.each do |line|
        p5.text(line, 320, ty)
        ty += title_font_height + leading
      end

      # Subtitle
      bottom_y = ty - leading + 12
      if metadata["subtitle"]
        p5.text_font(body_font)
        p5.text_color(text_color)
        p5.text(metadata["subtitle"], 320, bottom_y)
        bottom_y += body_font_height + 8
      end

      # Author
      if metadata["author"]
        p5.text_font(body_font)
        p5.text_color(separator_color)
        p5.text(metadata["author"], 320, bottom_y)
      end

      p5.text_align(:left)
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
      title_lines = title.split("\n")
      ty = title_y
      title_lines.each do |line|
        p5.text(line, margin_x, ty)
        ty += title_font_height + leading
      end
      # Separator line
      sep_y = ty - leading + 4
      p5.stroke(separator_color)
      p5.line(margin_x, sep_y, 640 - margin_x, sep_y)
      p5.no_stroke
      sep_y + 12
    end

    def align_x(p5, element, x)
      case element.align
      when :center
        p5.text_align(:center)
        320
      when :right
        p5.text_align(:right)
        640 - margin_x
      else
        p5.text_align(:left)
        x
      end
    end

    def align_image_x(element, image_width, x)
      case element.align
      when :center
        320 - image_width / 2
      when :right
        640 - margin_x - image_width
      else
        x
      end
    end

    def render_element(p5, element, x, y)
      case element.type
      when :text
        tx = align_x(p5, element, x)
        y = draw_rich_text(p5, element.text, tx, y)
        p5.text_align(:left)
        y
      when :bullet
        indent = x + element.level * bullet_indent
        p5.text_font(body_font)
        p5.text_color(text_color)
        p5.text(bullet_char, indent, y)
        draw_rich_text(p5, element.text, indent + bullet_width, y)
      when :numbered
        @numbered_counter += 1
        indent = x + element.level * bullet_indent
        p5.text_font(body_font)
        p5.text_color(text_color)
        label = "#{@numbered_counter}."
        p5.text(label, indent, y)
        draw_rich_text(p5, element.text, indent + bullet_width, y)
      when :blockquote
        render_blockquote(p5, element.text, x, y)
      when :image
        bmp = load_image(element.text)
        ix = align_image_x(element, bmp.width, x)
        p5.image_masked(bmp.data, bmp.mask, ix, y, bmp.width, bmp.height)
        y + bmp.height + leading
      when :code_block
        render_code_block(p5, element.text, x, y)
      when :p5_code
        render_p5_code(p5, element.text, x, y)
      when :blank
        y + body_font_height / 2
      else
        y
      end
    end

    # Draw text with inline **bold** and `code` formatting.
    # Returns the next Y position.
    def draw_rich_text(p5, str, x, y)
      segments = parse_inline(str)
      cx = x
      segments.each do |seg|
        case seg[0]
        when :bold
          p5.text_font(bold_font)
          p5.text_color(text_color)
          p5.text(seg[1], cx, y)
          cx += p5.text_width(seg[1])
        when :code
          p5.text_font(inline_code_font)
          p5.text_color(inline_code_color)
          code_y = y + body_font_ascent - inline_code_font_ascent
          p5.text(seg[1], cx, code_y)
          cx += p5.text_width(seg[1])
        else
          p5.text_font(body_font)
          p5.text_color(text_color)
          p5.text(seg[1], cx, y)
          cx += p5.text_width(seg[1])
        end
      end
      y + body_font_height + leading
    end

    # Parse inline formatting markers into segments.
    # Returns array of [:normal, text], [:bold, text], [:code, text]
    def parse_inline(str)
      segments = []
      i = 0
      len = str.length
      buf = ""

      while i < len
        if str[i] == "`"
          segments << [:normal, buf] if buf.length > 0
          buf = ""
          i += 1
          while i < len && str[i] != "`"
            buf << str[i]
            i += 1
          end
          segments << [:code, buf] if buf.length > 0
          buf = ""
          i += 1
        elsif i + 1 < len && str[i] == "*" && str[i + 1] == "*"
          segments << [:normal, buf] if buf.length > 0
          buf = ""
          i += 2
          while i + 1 < len && !(str[i] == "*" && str[i + 1] == "*")
            buf << str[i]
            i += 1
          end
          # Handle case where closing ** is at end
          if i < len && str[i] == "*"
            i += 2
          end
          segments << [:bold, buf] if buf.length > 0
          buf = ""
        else
          buf << str[i]
          i += 1
        end
      end
      segments << [:normal, buf] if buf.length > 0
      segments
    end

    def render_blockquote(p5, text, x, y)
      bar_x = x + 4
      text_x = x + 16
      # Left border bar
      p5.fill(separator_color)
      p5.no_stroke
      p5.rect(bar_x, y, 3, body_font_height)
      p5.no_fill
      p5.text_font(body_font)
      p5.text_color(blockquote_color)
      p5.text(text, text_x, y)
      y + body_font_height + leading
    end

    def load_image(path)
      path = "/#{path}" unless path.start_with?("/")
      @image_cache[path] ||= BMP.load(path)
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

    def render_p5_code(p5, lines, x, y)
      $__picorabbit_p5 = p5
      $__picorabbit_x = x
      $__picorabbit_y = y
      code = "loop do\np5 = $__picorabbit_p5\nx = $__picorabbit_x\ny = $__picorabbit_y\n" +
             lines.join("\n") + "\nTask.current.suspend\nend"
      if @p5_last_code != code
        @p5_last_code = code
        @p5_sandbox = Sandbox.new("p5_draw")
        @p5_sandbox.compile(code)
        @p5_sandbox.execute
      else
        @p5_sandbox.resume
      end
      @p5_sandbox.wait
      y
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
    def margin_y; 40; end
    def title_y; 40; end
    def body_y; 100; end
    def content_width; 560; end
    def leading; 4; end
    def bullet_indent; 20; end
    def bullet_char; "-"; end
    def bullet_width; 16; end

    # Font accessors (override in subclasses)

    def title_font; G::FONT_INTER_BOLD_24; end
    def title_font_height; G.font_height(title_font); end
    def body_font; G::FONT_INTER_18; end
    def body_font_height; G.font_height(body_font); end
    def body_font_ascent; 22; end
    def bold_font; G::FONT_INTER_BOLD_18; end
    def inline_code_font; G::FONT_SOURCE_CODE_PRO_18; end
    def inline_code_font_ascent; 12; end
    def code_font; G::FONT_SOURCE_CODE_PRO_18; end
    def code_font_height; G.font_height(code_font); end
    def footer_font; G::FONT_FIXED_5X7; end
    def footer_font_height; G.font_height(footer_font); end

    # Color accessors (override in subclasses)

    def background_color; 0xFF; end
    def title_color; 0x00; end
    def text_color; 0x00; end
    def blockquote_color; 0x49; end
    def separator_color; 0x49; end
    def inline_code_color; 0xE0; end
    def code_background_color; 0x49; end
    def code_text_color; 0xFF; end
    def footer_color; 0x49; end
    def track_color; 0x49; end
  end
end
