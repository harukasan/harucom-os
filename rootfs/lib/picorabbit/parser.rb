module PicoRabbit
  class ParseResult
    attr_reader :slides, :metadata

    def initialize(slides, metadata)
      @slides = slides
      @metadata = metadata
    end

    def theme
      @metadata["theme"]
    end
  end

  class Parser
    def self.parse_file(path)
      content = File.open(path, "r") { |f| f.read }
      parse(content)
    end

    def self.parse(content)
      slides = []
      current_title = nil
      current_elements = []
      in_code_block = false
      code_block_type = :code_block
      code_lines = []
      metadata = {}

      lines = split_lines(content)

      # Parse YAML frontmatter (--- delimited block at the start)
      if lines.length > 0 && lines[0].strip == "---"
        lines.shift
        while lines.length > 0
          line = lines.shift
          break if line.strip == "---"
          idx = line.index(":")
          if idx
            key = line[0, idx].strip
            val = line[idx + 1, line.length - idx - 1].strip
            metadata[key] = val
          end
        end
      end

      # Generate title slide from frontmatter
      if metadata["title"]
        s = Slide.new(metadata["title"].gsub("<br>", "\n"), [])
        s.title_slide = true
        slides << s
      end

      lines.each do |line|
        # Code block fence
        if line.strip.start_with?("```")
          if in_code_block
            current_elements << Element.new(code_block_type, code_lines)
            code_lines = []
            code_block_type = :code_block
            in_code_block = false
          else
            lang = line.strip[3, line.strip.length - 3]
            code_block_type = case lang
                              when "p5" then :p5_code
                              when "p5_setup" then :p5_setup
                              else :code_block
                              end
            in_code_block = true
          end
          next
        end

        if in_code_block
          code_lines << line
          next
        end

        # Heading: start a new slide
        if line.start_with?("# ")
          # Save previous slide
          if current_title
            slides << Slide.new(current_title, current_elements)
          end
          current_title = line[2, line.length - 2].strip.gsub("<br>", "\n")
          current_elements = []
          next
        end

        # Wait marker: {::wait/}
        if line.strip == "{::wait/}"
          current_elements << Element.new(:wait)
          next
        end

        # Alignment directive: {:.center} or {:.right}
        s = line.strip
        if s == "{:.center}" || s == "{:.right}"
          if current_elements.length > 0
            align = s == "{:.center}" ? :center : :right
            current_elements[current_elements.length - 1].align = align
          end
          next
        end

        # Image: ![alt](path)
        stripped_line = line.strip
        if stripped_line.start_with?("![")
          paren = stripped_line.index("](")
          if paren
            close = stripped_line.index(")", paren + 2)
            if close
              path = stripped_line[paren + 2, close - paren - 2]
              current_elements << Element.new(:image, path)
              next
            end
          end
        end

        # Blank line
        if line.strip.length == 0
          current_elements << Element.new(:blank)
          next
        end

        # Blockquote
        stripped = line.lstrip
        if stripped.start_with?("> ")
          text = stripped[2, stripped.length - 2]
          current_elements << Element.new(:blockquote, text)
          next
        end

        # Bullet list
        if stripped.start_with?("- ") || stripped.start_with?("* ")
          indent = line.length - stripped.length
          level = indent / 2
          text = stripped[2, stripped.length - 2]
          current_elements << Element.new(:bullet, text, level)
          next
        end

        # Numbered list (1. text, 2. text, etc.)
        dot_pos = stripped.index(". ")
        if dot_pos && dot_pos > 0 && dot_pos <= 3
          num_str = stripped[0, dot_pos]
          all_digits = true
          i = 0
          while i < num_str.length
            c = num_str[i]
            unless c >= "0" && c <= "9"
              all_digits = false
              break
            end
            i += 1
          end
          if all_digits
            indent = line.length - stripped.length
            level = indent / 2
            text = stripped[dot_pos + 2, stripped.length - dot_pos - 2]
            current_elements << Element.new(:numbered, text, level)
            next
          end
        end

        # Plain text
        current_elements << Element.new(:text, line.strip)
      end

      # Surface an unterminated code block instead of silently swallowing
      # the rest of the file. The error element renders via the theme's
      # render_error path so it is visible during the presentation.
      if in_code_block
        lang = code_block_type == :p5_code ? "p5" : (code_block_type == :p5_setup ? "p5_setup" : "code")
        current_elements << Element.new(:error, "[parse] unclosed ```#{lang} code block at end of file")
        if code_lines.length > 0
          current_elements << Element.new(code_block_type, code_lines)
        end
      end

      # Save last slide
      if current_title
        slides << Slide.new(current_title, current_elements)
      end

      ParseResult.new(slides, metadata)
    end

    private

    def self.split_lines(str)
      result = []
      start = 0
      i = 0
      len = str.length
      while i < len
        if str[i] == "\n"
          result << str[start, i - start]
          start = i + 1
        end
        i += 1
      end
      result << str[start, len - start] if start < len
      result
    end
  end
end
