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

    def idle?
      @stroke1.nil?
    end

    def process(key, im)
      # Backspace takes back a stroke still waiting for its partner, the way
      # it takes back a romaji character in SKK. Held with a modifier it is a
      # different key and belongs to the application.
      unmodified = { ctrl: false, shift: false, alt: false, super_key: false }
      if @stroke1 && key.match?(:bspace, **unmodified)
        @stroke1 = nil
        im.set_preedit("")
        return :consumed
      end

      # Escape and Ctrl-G abandon it as well, the way they cancel a conversion
      # in SKK.
      if @stroke1 && (key.match?(:escape, **unmodified) || key.match?(:g, ctrl: true))
        @stroke1 = nil
        im.set_preedit("")
        return :consumed
      end

      ch = key.printable? ? key.to_s : nil
      pos = ch ? KEY_POSITIONS[ch] : nil

      # A key with no place in the layout ends the pair.
      unless pos
        return :passthrough unless @stroke1

        pending = @stroke1
        @stroke1 = nil
        im.set_preedit("")
        # A key that carries text goes in behind the stroke. One that does not
        # is consumed here, the way an IME consumes the key that ends a
        # composition, so it cannot act on a buffer this flush just changed.
        im.commit(ch ? pending + ch : pending)
        return :commit
      end

      now = Machine.board_millis

      # A stroke left alone for too long is not part of a pair. Commit it
      # as a normal character and start a new pair from this key.
      if @stroke1 && (now - @stroke1_ms) >= TIMEOUT_MS
        im.commit(@stroke1)
        @stroke1 = ch
        @stroke1_ms = now
        im.set_preedit(ch)
        return :commit
      end

      if @stroke1
        # Second stroke
        pending = @stroke1
        pos1 = KEY_POSITIONS[pending]
        @stroke1 = nil
        im.set_preedit("")

        result = InputMethod.tcode_lookup(pos1, pos)
        if result
          im.commit(result)
        else
          # No match: output both keys as normal characters
          im.commit(pending + ch)
        end
        return :commit
      end

      # First stroke
      @stroke1 = ch
      @stroke1_ms = now
      im.set_preedit(ch)
      :consumed
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
