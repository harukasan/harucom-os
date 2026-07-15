# Byte-indexed JSON parser for fixture definitions.
#
# The stdlib JSON gem walks the document with character indexing
# (json[index]), which rescans the string from the start on every
# access under MRB_UTF8_STRING. That is O(n^2): a 5.9 KB fixture file
# costs about 17 million scan steps and parses in seconds on the
# board. This parser reads bytes with getbyte/byteslice, so it stays
# O(n) regardless of string encoding and code placement.
#
# Supports the full JSON grammar: objects, arrays, strings with
# escapes (including \uXXXX), numbers, true/false/null. Raises
# ArgumentError on malformed input.

module DMX
  module JSONParser
    QUOTE     = 34   # '"'
    BACKSLASH = 92   # '\\'

    def self.parse(text)
      state = [text, 0] # position carried across parse calls
      skip_whitespace(state)
      value = parse_value(state)
      skip_whitespace(state)
      if state[1] < text.bytesize
        raise ArgumentError, "JSON: trailing bytes at #{state[1]}"
      end
      value
    end

    def self.skip_whitespace(state)
      text = state[0]
      pos = state[1]
      while (b = text.getbyte(pos)) && (b == 32 || b == 9 || b == 10 || b == 13)
        pos += 1
      end
      state[1] = pos
    end

    def self.parse_value(state)
      text = state[0]
      b = text.getbyte(state[1])
      raise ArgumentError, "JSON: unexpected end of input" unless b
      case b
      when 123 then parse_object(state)  # '{'
      when 91  then parse_array(state)   # '['
      when QUOTE then parse_string(state)
      when 116  # 't'
        expect_word(state, "true")
        true
      when 102  # 'f'
        expect_word(state, "false")
        false
      when 110  # 'n'
        expect_word(state, "null")
        nil
      else
        parse_number(state)
      end
    end

    def self.expect_word(state, word)
      pos = state[1]
      unless state[0].byteslice(pos, word.bytesize) == word
        raise ArgumentError, "JSON: unexpected token at #{pos}"
      end
      state[1] = pos + word.bytesize
    end

    def self.parse_object(state)
      result = {}
      state[1] += 1 # past '{'
      skip_whitespace(state)
      if state[0].getbyte(state[1]) == 125 # '}'
        state[1] += 1
        return result
      end
      loop do
        skip_whitespace(state)
        unless state[0].getbyte(state[1]) == QUOTE
          raise ArgumentError, "JSON: expected object key at #{state[1]}"
        end
        key = parse_string(state)
        skip_whitespace(state)
        unless state[0].getbyte(state[1]) == 58 # ':'
          raise ArgumentError, "JSON: expected ':' at #{state[1]}"
        end
        state[1] += 1
        skip_whitespace(state)
        result[key] = parse_value(state)
        skip_whitespace(state)
        b = state[0].getbyte(state[1])
        state[1] += 1
        break if b == 125            # '}'
        next if b == 44              # ','
        raise ArgumentError, "JSON: expected ',' or '}' at #{state[1] - 1}"
      end
      result
    end

    def self.parse_array(state)
      result = []
      state[1] += 1 # past '['
      skip_whitespace(state)
      if state[0].getbyte(state[1]) == 93 # ']'
        state[1] += 1
        return result
      end
      loop do
        skip_whitespace(state)
        result << parse_value(state)
        skip_whitespace(state)
        b = state[0].getbyte(state[1])
        state[1] += 1
        break if b == 93             # ']'
        next if b == 44              # ','
        raise ArgumentError, "JSON: expected ',' or ']' at #{state[1] - 1}"
      end
      result
    end

    # Fast path: a string without backslashes is one byteslice. The
    # escape path rebuilds the string from safe spans.
    def self.parse_string(state)
      text = state[0]
      start = state[1] + 1 # past opening quote
      pos = start
      has_escape = false
      while (b = text.getbyte(pos))
        if b == QUOTE
          state[1] = pos + 1
          slice = text.byteslice(start, pos - start).to_s
          return has_escape ? unescape(slice) : slice
        end
        if b == BACKSLASH
          has_escape = true
          pos += 2
        else
          pos += 1
        end
      end
      raise ArgumentError, "JSON: unterminated string at #{start - 1}"
    end

    def self.unescape(slice)
      result = ""
      pos = 0
      span = 0 # start of the current backslash-free span
      size = slice.bytesize
      while pos < size
        if slice.getbyte(pos) == BACKSLASH
          result << slice.byteslice(span, pos - span).to_s if pos > span
          code = slice.getbyte(pos + 1)
          case code
          when QUOTE     then result << "\""
          when BACKSLASH then result << "\\"
          when 47  then result << "/"
          when 98  then result << "\b"
          when 102 then result << "\f"
          when 110 then result << "\n"
          when 114 then result << "\r"
          when 116 then result << "\t"
          when 117 # 'u'
            hex = slice.byteslice(pos + 2, 4).to_s
            unless hex.bytesize == 4 && hex_digits?(hex)
              raise ArgumentError, "JSON: bad unicode escape"
            end
            codepoint = hex.to_i(16)
            if codepoint >= 0xD800 && codepoint <= 0xDBFF
              # Surrogate pair: the low half must follow as \uXXXX.
              low_hex = slice.byteslice(pos + 8, 4).to_s
              unless slice.getbyte(pos + 6) == BACKSLASH &&
                     slice.getbyte(pos + 7) == 117 &&
                     low_hex.bytesize == 4 && hex_digits?(low_hex)
                raise ArgumentError, "JSON: unpaired surrogate"
              end
              low = low_hex.to_i(16)
              unless low >= 0xDC00 && low <= 0xDFFF
                raise ArgumentError, "JSON: unpaired surrogate"
              end
              codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
              pos += 6
            elsif codepoint >= 0xDC00 && codepoint <= 0xDFFF
              raise ArgumentError, "JSON: unpaired surrogate"
            end
            result << utf8_encode(codepoint)
            pos += 4
          else
            raise ArgumentError, "JSON: bad escape \\#{code}"
          end
          pos += 2
          span = pos
        else
          pos += 1
        end
      end
      result << slice.byteslice(span, pos - span).to_s if pos > span
      result
    end

    def self.hex_digits?(text)
      i = 0
      while i < text.bytesize
        b = text.getbyte(i)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
        return false unless ok
        i += 1
      end
      true
    end

    def self.utf8_encode(codepoint)
      if codepoint < 0x80
        codepoint.chr
      elsif codepoint < 0x800
        (0xC0 | (codepoint >> 6)).chr + (0x80 | (codepoint & 0x3F)).chr
      elsif codepoint < 0x10000
        (0xE0 | (codepoint >> 12)).chr +
          (0x80 | ((codepoint >> 6) & 0x3F)).chr +
          (0x80 | (codepoint & 0x3F)).chr
      else
        (0xF0 | (codepoint >> 18)).chr +
          (0x80 | ((codepoint >> 12) & 0x3F)).chr +
          (0x80 | ((codepoint >> 6) & 0x3F)).chr +
          (0x80 | (codepoint & 0x3F)).chr
      end
    end

    def self.parse_number(state)
      text = state[0]
      start = state[1]
      pos = start
      float = false
      pos += 1 if text.getbyte(pos) == 45 # '-'
      digits = pos
      while (b = text.getbyte(pos)) && b >= 48 && b <= 57
        pos += 1
      end
      if pos == digits
        raise ArgumentError, "JSON: unexpected byte at #{start}"
      end
      if text.getbyte(digits) == 48 && pos - digits > 1 # leading zero
        raise ArgumentError, "JSON: leading zero at #{start}"
      end
      if text.getbyte(pos) == 46 # '.'
        float = true
        pos += 1
        digits = pos
        while (b = text.getbyte(pos)) && b >= 48 && b <= 57
          pos += 1
        end
        raise ArgumentError, "JSON: digits expected at #{pos}" if pos == digits
      end
      b = text.getbyte(pos)
      if b == 101 || b == 69 # e E
        float = true
        pos += 1
        b = text.getbyte(pos)
        pos += 1 if b == 43 || b == 45
        digits = pos
        while (b = text.getbyte(pos)) && b >= 48 && b <= 57
          pos += 1
        end
        raise ArgumentError, "JSON: digits expected at #{pos}" if pos == digits
      end
      state[1] = pos
      literal = text.byteslice(start, pos - start).to_s
      float ? literal.to_f : literal.to_i
    end
  end
end
