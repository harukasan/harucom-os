module PicoRabbit
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
      code_lines = []

      lines = split_lines(content)
      lines.each do |line|
        # Code block fence
        if line.strip.start_with?("```")
          if in_code_block
            current_elements << Element.new(:code_block, code_lines)
            code_lines = []
            in_code_block = false
          else
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
          current_title = line[2, line.length - 2].strip
          current_elements = []
          next
        end

        # Blank line
        if line.strip.length == 0
          current_elements << Element.new(:blank)
          next
        end

        # Bullet list
        stripped = line.lstrip
        if stripped.start_with?("- ") || stripped.start_with?("* ")
          indent = line.length - stripped.length
          level = indent / 2
          text = stripped[2, stripped.length - 2]
          current_elements << Element.new(:bullet, text, level)
          next
        end

        # Plain text
        current_elements << Element.new(:text, line.strip)
      end

      # Close any unclosed code block
      if in_code_block && code_lines.length > 0
        current_elements << Element.new(:code_block, code_lines)
      end

      # Save last slide
      if current_title
        slides << Slide.new(current_title, current_elements)
      end

      slides
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
