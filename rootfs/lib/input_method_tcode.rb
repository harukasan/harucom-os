# InputMethod::TCode - T-Code direct kanji input engine
#
# Two-stroke input: each pair of keystrokes maps to a kanji character
# via a 40x40 lookup table stored in the flash dictionary region.

class InputMethod
  class TCode
    # Map keyboard characters to T-Code key positions (0-39)
    KEY_POSITIONS = {
      "1" =>  0, "2" =>  1, "3" =>  2, "4" =>  3, "5" =>  4,
      "6" =>  5, "7" =>  6, "8" =>  7, "9" =>  8, "0" =>  9,
      "q" => 10, "w" => 11, "e" => 12, "r" => 13, "t" => 14,
      "y" => 15, "u" => 16, "i" => 17, "o" => 18, "p" => 19,
      "a" => 20, "s" => 21, "d" => 22, "f" => 23, "g" => 24,
      "h" => 25, "j" => 26, "k" => 27, "l" => 28, ";" => 29,
      "z" => 30, "x" => 31, "c" => 32, "v" => 33, "b" => 34,
      "n" => 35, "m" => 36, "," => 37, "." => 38, "/" => 39,
    }

    TIMEOUT_MS = 500

    def initialize
      @stroke1 = nil        # first keystroke character, or nil
      @stroke1_ms = 0       # timestamp of first stroke
    end

    def process(key, im)
      # Check timeout on first stroke
      if @stroke1
        now = Machine.board_millis
        if (now - @stroke1_ms) >= TIMEOUT_MS
          # Timeout: pass first stroke as normal character
          ch = @stroke1
          @stroke1 = nil
          im.set_preedit("")
          im.commit(ch)
          # Continue processing current key below (may start a new stroke)
        end
      end

      return :passthrough unless key.printable?

      ch = key.to_s
      pos = KEY_POSITIONS[ch]

      # Key not in T-Code layout: pass through (also flush pending stroke)
      unless pos
        if @stroke1
          pending = @stroke1
          @stroke1 = nil
          im.set_preedit("")
          im.commit(pending)
          return :commit
        end
        return :passthrough
      end

      if @stroke1
        # Second stroke
        pos1 = KEY_POSITIONS[@stroke1]
        @stroke1 = nil
        im.set_preedit("")

        result = InputMethod.tcode_lookup(pos1, pos)
        if result
          im.commit(result)
          return :commit
        else
          # No match: output both keys as normal characters
          im.commit(ch)
          return :commit
        end
      else
        # First stroke
        @stroke1 = ch
        @stroke1_ms = Machine.board_millis
        im.set_preedit(ch)
        return :consumed
      end
    end

    def mode_label
      "[漢]"
    end

    def reset(im)
      if @stroke1
        im.commit(@stroke1)
        @stroke1 = nil
      end
      im.set_preedit("")
    end
  end
end
