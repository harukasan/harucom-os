module PicoRabbit
  module Themes
    # Kansai RubyKaigi 09 theme. Designed for small projection screens:
    # M PLUS 1 fonts at 48px (title) and 32px (body) for both Latin and
    # Japanese glyphs. The Japanese fonts are subsetted to the characters
    # used in the kanrk09 slide deck (see picoruby-dvi/mrbgem.rake).
    class Kanrk09 < Theme
      ACCENT = 0x01  # deep blue (RGB332)

      # Fonts
      def title_font; G::FONT_MPLUS_1_EXTRABOLD_48_LATIN; end
      def title_wide_font; G::FONT_MPLUS_1_EXTRABOLD_48_JAPANESE; end
      def body_font; G::FONT_MPLUS_1_MEDIUM_32_LATIN; end
      def body_wide_font; G::FONT_MPLUS_1_MEDIUM_32_JAPANESE; end
      def bold_font; G::FONT_MPLUS_1_EXTRABOLD_32_LATIN; end
      def bold_wide_font; G::FONT_MPLUS_1_EXTRABOLD_32_JAPANESE; end
      def inline_code_font; G::FONT_SOURCE_CODE_PRO_20; end
      def code_font; G::FONT_SOURCE_CODE_PRO_20; end
      def footer_font; G::FONT_SPLEEN_8X16; end

      # Baseline rows (M PLUS 1 ascender is 38 at 32px, Source Code Pro 20)
      def body_font_ascent; 38; end
      def inline_code_font_ascent; 20; end

      # Colors
      def background_color; 0xFF; end
      def title_color; ACCENT; end
      def text_color; 0x00; end
      def separator_color; ACCENT; end
      def footer_color; 0x49; end
      def track_color; ACCENT; end

      # Layout
      def margin_x; 32; end
      def margin_y; 16; end
      def title_y; 16; end
      def body_y; 60; end
      def content_width; 576; end
      def leading; 4; end
      def bullet_indent; 28; end
      def bullet_width; 32; end
      def bullet_size; 13; end

      # Title slide: accent background, white centered title
      def render_title_slide(p5, slide, metadata)
        p5.background(ACCENT)

        title_lines = slide.title.split("\n")
        author_lines = metadata["author"] ? Parser.replace_br(metadata["author"]).split("\n") : []
        total_height = title_lines.length * (title_font_height + leading) - leading
        total_height += 16 + body_font_height if metadata["subtitle"]
        total_height += 8 + author_lines.length * (body_font_height + leading) - leading if author_lines.length > 0
        y = (480 - total_height) / 2

        p5.text_font(title_font, title_wide_font)
        p5.text_color(0xFF)
        p5.text_align(:center)
        title_lines.each do |line|
          p5.text(line, 320, y)
          y += title_font_height + leading
        end
        y -= leading

        if metadata["subtitle"]
          y += 16
          p5.text_font(body_font, body_wide_font)
          p5.text_color(0xDB)
          p5.text(metadata["subtitle"], 320, y)
          y += body_font_height
        end
        if author_lines.length > 0
          y += 8
          p5.text_font(body_font, body_wide_font)
          p5.text_color(0xDB)
          author_lines.each do |line|
            p5.text(line, 320, y)
            y += body_font_height + leading
          end
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

      # Page number below the timer track (456) so they do not overlap
      def render_footer(p5, slide_index, total_slides)
        p5.text_font(footer_font)
        p5.text_color(footer_color)
        p5.text_align(:right)
        p5.text("#{slide_index + 1} / #{total_slides}", 640 - margin_x, 462)
        p5.text_align(:left)
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

      # Bullet mark: accent color square (M PLUS 1 has no star glyph),
      # centered on the character box of the 48px body font.
      def render_element(p5, element, x, y)
        if element.type == :bullet
          indent = x + element.level * bullet_indent
          p5.text_align(:left)
          p5.fill(ACCENT)
          p5.no_stroke
          p5.rect(indent, y + (body_font_ascent - bullet_size) / 2 + 3, bullet_size, bullet_size)
          p5.no_fill
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
        p5.text_font(title_font, title_wide_font)
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
              p5.text_font(bold_font, bold_wide_font)
            else
              p5.text_font(body_font, body_wide_font)
            end
            total_w += p5.text_width(seg[1])
          end
          cx = 320 - total_w / 2
          segments.each do |seg|
            if seg[0] == :bold
              p5.text_font(bold_font, bold_wide_font)
            else
              p5.text_font(body_font, body_wide_font)
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
