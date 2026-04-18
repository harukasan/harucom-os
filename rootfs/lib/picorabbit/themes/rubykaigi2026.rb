module PicoRabbit
  module Themes
    class Rubykaigi2026 < Theme
      ACCENT = 0x64  # RGB332 closest to #7F412B

      # Fonts
      def title_font; G::FONT_OUTFIT_EXTRABOLD_32; end
      def body_font; G::FONT_OUTFIT_22; end
      def bold_font; G::FONT_OUTFIT_BOLD_22; end

      # Colors
      def background_color; 0xFF; end
      def title_color; ACCENT; end
      def text_color; 0x00; end
      def separator_color; ACCENT; end
      def footer_color; 0x49; end
      def track_color; ACCENT; end

      # Bullet
      def bullet_char; "\xe2\x98\x85"; end
      def bullet_width; 24; end

      def margin_y; 30; end
      def title_y; 30; end
      def body_y; 50; end

      # Title slide: background image
      def render_title_slide(p5, slide, metadata)
        bmp = load_image("/data/rubykaigi2026_title.bmp")
        p5.image(bmp.data, 0, 0, bmp.width, bmp.height)

        p5.text_font(title_font)
        p5.text_color(0xFF)
        p5.text_align(:center)
        title_lines = slide.title.split("\n")
        ty = 180
        title_lines.each do |line|
          p5.text(line, 320, ty)
          ty += title_font_height + leading
        end

        bottom_y = ty - leading + 12
        if metadata["subtitle"]
          p5.text_font(body_font)
          p5.text_color(0xDB)
          p5.text(metadata["subtitle"], 320, bottom_y)
          bottom_y += body_font_height + 8
        end
        if metadata["author"]
          p5.text_font(body_font)
          p5.text_color(0xDB)
          p5.text(metadata["author"], 320, bottom_y)
        end
        p5.text_align(:left)
      end

      # Normal slides: white background + accent color top bar
      def render_background(p5)
        p5.background(background_color)
        p5.fill(ACCENT)
        p5.no_stroke
        p5.rect(0, 0, 640, 10)
        p5.no_fill
      end

      def render_slide(p5, slide, slide_index, total_slides, step = nil, metadata = {})
        if !slide.title_slide && title_only?(slide)
          p5.background(ACCENT)
          render_centered_slide(p5, slide)
          render_footer(p5, slide_index, total_slides)
        else
          super
        end
      end

      # Bullet char in accent color, body text in black
      def render_element(p5, element, x, y)
        if element.type == :bullet
          indent = x + element.level * bullet_indent
          p5.text_align(:left)
          p5.text_font(G::FONT_INTER_SYMBOLS_22)
          p5.text_color(ACCENT)
          p5.text(bullet_char, indent, y)
          p5.text_font(body_font)
          draw_rich_text(p5, element.text, indent + bullet_width, y)
        else
          super
        end
      end

      private

      def title_only?(slide)
        slide.elements.all? { |e| e.type == :blank || e.type == :text }
      end

      def render_centered_slide(p5, slide)
        texts = slide.elements.select { |e| e.type == :text }

        # Calculate total content height for vertical centering
        total_height = title_font_height
        if texts.length > 0
          total_height += 16
          texts.each { total_height += body_font_height + leading }
          total_height -= leading
        end
        y = (480 - total_height) / 2

        # Title
        p5.text_font(title_font)
        p5.text_color(0xFF)
        p5.text_align(:center)
        p5.text(slide.title, 320, y)
        y += title_font_height + 16

        # Body text (centered rich text)
        p5.text_align(:left)
        texts.each do |element|
          segments = parse_inline(element.text)
          # Calculate total width for centering
          total_w = 0
          segments.each do |seg|
            if seg[0] == :bold
              p5.text_font(bold_font)
            else
              p5.text_font(body_font)
            end
            total_w += p5.text_width(seg[1])
          end
          cx = 320 - total_w / 2
          segments.each do |seg|
            if seg[0] == :bold
              p5.text_font(bold_font)
            else
              p5.text_font(body_font)
            end
            p5.text_color(0xDB)
            p5.text(seg[1], cx, y)
            cx += p5.text_width(seg[1])
          end
          y += body_font_height + leading
        end

        p5.text_align(:left)
      end
    end
  end
end
