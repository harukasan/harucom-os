# InputMethod::SKK - SKK Japanese input engine
#
# Modes:
#   :hiragana  - Romaji-to-hiragana conversion
#   :katakana  - Romaji-to-katakana conversion
#   :kanji     - Accumulating reading for kanji lookup (▽)
#   :candidate - Selecting from kanji candidates (▼)

class InputMethod
  class SKK
    ROMAJI_TABLE = {
      "a" => "あ", "i" => "い", "u" => "う", "e" => "え", "o" => "お",
      "ka" => "か", "ki" => "き", "ku" => "く", "ke" => "け", "ko" => "こ",
      "sa" => "さ", "si" => "し", "su" => "す", "se" => "せ", "so" => "そ",
      "ta" => "た", "ti" => "ち", "tu" => "つ", "te" => "て", "to" => "と",
      "na" => "な", "ni" => "に", "nu" => "ぬ", "ne" => "ね", "no" => "の",
      "ha" => "は", "hi" => "ひ", "hu" => "ふ", "he" => "へ", "ho" => "ほ",
      "ma" => "ま", "mi" => "み", "mu" => "む", "me" => "め", "mo" => "も",
      "ya" => "や", "yu" => "ゆ", "yo" => "よ",
      "ra" => "ら", "ri" => "り", "ru" => "る", "re" => "れ", "ro" => "ろ",
      "wa" => "わ", "wi" => "ゐ", "we" => "ゑ", "wo" => "を",
      "nn" => "ん", "n'" => "ん",
      "ga" => "が", "gi" => "ぎ", "gu" => "ぐ", "ge" => "げ", "go" => "ご",
      "za" => "ざ", "zi" => "じ", "zu" => "ず", "ze" => "ぜ", "zo" => "ぞ",
      "da" => "だ", "di" => "ぢ", "du" => "づ", "de" => "で", "do" => "ど",
      "ba" => "ば", "bi" => "び", "bu" => "ぶ", "be" => "べ", "bo" => "ぼ",
      "pa" => "ぱ", "pi" => "ぴ", "pu" => "ぷ", "pe" => "ぺ", "po" => "ぽ",
      "kya" => "きゃ", "kyi" => "きぃ", "kyu" => "きゅ", "kye" => "きぇ", "kyo" => "きょ",
      "sya" => "しゃ", "syi" => "しぃ", "syu" => "しゅ", "sye" => "しぇ", "syo" => "しょ",
      "sha" => "しゃ", "shi" => "し", "shu" => "しゅ", "she" => "しぇ", "sho" => "しょ",
      "tya" => "ちゃ", "tyi" => "ちぃ", "tyu" => "ちゅ", "tye" => "ちぇ", "tyo" => "ちょ",
      "cha" => "ちゃ", "chi" => "ち", "chu" => "ちゅ", "che" => "ちぇ", "cho" => "ちょ",
      "nya" => "にゃ", "nyi" => "にぃ", "nyu" => "にゅ", "nye" => "にぇ", "nyo" => "にょ",
      "hya" => "ひゃ", "hyi" => "ひぃ", "hyu" => "ひゅ", "hye" => "ひぇ", "hyo" => "ひょ",
      "mya" => "みゃ", "myi" => "みぃ", "myu" => "みゅ", "mye" => "みぇ", "myo" => "みょ",
      "rya" => "りゃ", "ryi" => "りぃ", "ryu" => "りゅ", "rye" => "りぇ", "ryo" => "りょ",
      "gya" => "ぎゃ", "gyi" => "ぎぃ", "gyu" => "ぎゅ", "gye" => "ぎぇ", "gyo" => "ぎょ",
      "ja" => "じゃ", "ji" => "じ", "ju" => "じゅ", "je" => "じぇ", "jo" => "じょ",
      "jya" => "じゃ", "jyi" => "じぃ", "jyu" => "じゅ", "jye" => "じぇ", "jyo" => "じょ",
      "dya" => "ぢゃ", "dyi" => "ぢぃ", "dyu" => "ぢゅ", "dye" => "ぢぇ", "dyo" => "ぢょ",
      "bya" => "びゃ", "byi" => "びぃ", "byu" => "びゅ", "bye" => "びぇ", "byo" => "びょ",
      "pya" => "ぴゃ", "pyi" => "ぴぃ", "pyu" => "ぴゅ", "pye" => "ぴぇ", "pyo" => "ぴょ",
      "fa" => "ふぁ", "fi" => "ふぃ", "fu" => "ふ", "fe" => "ふぇ", "fo" => "ふぉ",
      "tsa" => "つぁ", "tsi" => "つぃ", "tsu" => "つ", "tse" => "つぇ", "tso" => "つぉ",
      "xa" => "ぁ", "xi" => "ぃ", "xu" => "ぅ", "xe" => "ぇ", "xo" => "ぉ",
      "xya" => "ゃ", "xyu" => "ゅ", "xyo" => "ょ",
      "xtu" => "っ", "xtsu" => "っ", "xwa" => "ゎ",
      "-" => "ー",
    }

    # Characters that trigger 'n' -> 'ん' flush (not vowels and not 'n' or 'y')
    N_FLUSH_CHARS = "bcdfghjklmpqrstvwxz"

    # Hiragana -> Katakana offset (Unicode block difference)
    KATA_OFFSET = 0x60  # U+30A0 - U+3040

    def initialize
      @mode = :hiragana
      @romaji = ""       # romaji accumulation buffer
      @reading = ""      # kanji reading accumulation (hiragana)
    end

    def process(key, im)
      case @mode
      when :hiragana, :katakana
        process_kana(key, im)
      when :kanji
        process_kanji(key, im)
      when :candidate
        process_candidate(key, im)
      else
        :passthrough
      end
    end

    def mode_label
      case @mode
      when :hiragana  then "[あ]"
      when :katakana  then "[ア]"
      when :kanji     then "[あ]"
      when :candidate then "[あ]"
      end
    end

    def reset(im)
      if @romaji.bytesize > 0
        im.commit(@romaji)
        @romaji = ""
      end
      if @mode == :kanji || @mode == :candidate
        im.commit(@reading) if @reading.bytesize > 0
        @reading = ""
        @mode = :hiragana
      end
      im.set_preedit("")
      im.clear_candidates
    end

    private

    def process_kana(key, im)
      # 'l' switches to ASCII mode (deactivate engine)
      if key.match?(:l, ctrl: false, shift: false)
        flush_n(im)
        im.set_engine(nil)
        return :consumed
      end

      # 'q' toggles hiragana/katakana
      if key.match?(:q, ctrl: false, shift: false)
        flush_n(im)
        @mode = (@mode == :hiragana) ? :katakana : :hiragana
        im.set_preedit("")
        return :consumed
      end

      # Backspace: delete last romaji character or pass through
      if key == Keyboard::BSPACE
        if @romaji.bytesize > 0
          @romaji = @romaji.byteslice(0, @romaji.bytesize - 1)
          im.set_preedit(@romaji)
          return :consumed
        end
        return :passthrough
      end

      # Non-printable keys: flush romaji and pass through
      unless key.printable?
        flush_romaji(im)
        return :passthrough
      end

      ch = key.to_s

      # Uppercase letter: start kanji entry mode
      if ch >= "A" && ch <= "Z"
        flush_n(im)
        @mode = :kanji
        @reading = ""
        @romaji = ch.downcase
        im.set_preedit("▽" + @romaji)
        return :consumed
      end

      # Accumulate romaji and try conversion
      @romaji += ch
      result = try_romaji_conversion
      if result
        kana = (@mode == :katakana) ? hiragana_to_katakana(result) : result
        im.commit(kana)
        im.set_preedit(@romaji)
        return :commit
      end

      # Check if current romaji could be a prefix of any table entry
      if romaji_has_prefix?(@romaji)
        im.set_preedit(@romaji)
        return :consumed
      end

      # No match possible: flush the romaji buffer as-is
      flush_text = @romaji
      @romaji = ""
      im.commit(flush_text)
      im.set_preedit("")
      return :commit
    end

    def process_kanji(key, im)
      # Escape / Ctrl-G: cancel kanji entry
      if key == Keyboard::ESCAPE || key.match?(:g, ctrl: true)
        @reading = ""
        @romaji = ""
        @mode = :hiragana
        im.set_preedit("")
        im.clear_candidates
        return :consumed
      end

      # Backspace: delete last character
      if key == Keyboard::BSPACE
        if @romaji.bytesize > 0
          @romaji = @romaji.byteslice(0, @romaji.bytesize - 1)
        elsif @reading.bytesize > 0
          # Remove last kana character (variable byte length)
          pos = Editor.prev_char_byte_pos(@reading, @reading.bytesize)
          @reading = @reading.byteslice(0, pos)
        end
        if @reading.bytesize == 0 && @romaji.bytesize == 0
          @mode = :hiragana
          im.set_preedit("")
        else
          im.set_preedit("▽" + @reading + @romaji)
        end
        return :consumed
      end

      # Space: look up reading in dictionary
      if key == Keyboard::SPACE
        flush_n_to_reading
        if @reading.bytesize > 0
          candidates = InputMethod.skk_lookup(@reading)
          if candidates
            im.set_candidates(candidates, 0)
            im.set_preedit("▼" + candidates[0])
            @mode = :candidate
            return :consumed
          end
        end
        # No candidates found
        im.set_preedit("▽" + @reading)
        return :consumed
      end

      # Enter: commit reading as-is (no conversion)
      if key == Keyboard::ENTER
        flush_n_to_reading
        im.commit(@reading)
        @reading = ""
        @romaji = ""
        @mode = :hiragana
        return :commit
      end

      return :passthrough unless key.printable?

      ch = key.to_s

      # Accumulate romaji for reading
      @romaji += ch.downcase
      result = try_romaji_conversion
      if result
        @reading += result
        im.set_preedit("▽" + @reading + @romaji)
        return :consumed
      end

      im.set_preedit("▽" + @reading + @romaji)
      :consumed
    end

    def process_candidate(key, im)
      candidates = im.candidates
      idx = im.candidate_index

      # Space: next candidate
      if key == Keyboard::SPACE
        if candidates && idx + 1 < candidates.length
          idx += 1
          im.set_candidates(candidates, idx)
          im.set_preedit("▼" + candidates[idx])
        end
        return :consumed
      end

      # 'x': previous candidate
      if key.match?(:x, ctrl: false, shift: false)
        if idx > 0
          idx -= 1
          im.set_candidates(candidates, idx)
          im.set_preedit("▼" + candidates[idx])
        else
          # Back to kanji entry mode
          @mode = :kanji
          im.clear_candidates
          im.set_preedit("▽" + @reading)
        end
        return :consumed
      end

      # Escape / Ctrl-G: cancel
      if key == Keyboard::ESCAPE || key.match?(:g, ctrl: true)
        @mode = :kanji
        im.clear_candidates
        im.set_preedit("▽" + @reading)
        return :consumed
      end

      # Enter: confirm current candidate
      if key == Keyboard::ENTER
        if candidates && candidates[idx]
          im.commit(candidates[idx])
        end
        @reading = ""
        @romaji = ""
        @mode = :hiragana
        return :commit
      end

      # Any other printable key: confirm candidate and process the key
      if key.printable? && candidates && candidates[idx]
        im.commit(candidates[idx])
        @reading = ""
        @romaji = ""
        @mode = :hiragana
        # Process this key in kana mode
        result = process_kana(key, im)
        return result == :commit ? :commit : :commit
      end

      :passthrough
    end

    # Try to convert the romaji buffer. Returns the kana string if matched,
    # or nil. Updates @romaji to contain the unconsumed remainder.
    def try_romaji_conversion
      # Double consonant -> sokuon (っ) + keep second consonant
      if @romaji.bytesize >= 2
        c1 = @romaji.byteslice(0, 1)
        c2 = @romaji.byteslice(1, 1)
        if c1 == c2 && c1 != "a" && c1 != "i" && c1 != "u" && c1 != "e" && c1 != "o" && c1 != "n"
          @romaji = @romaji.byteslice(1, @romaji.bytesize - 1)
          return "っ"
        end
      end

      # Try longest match first
      len = @romaji.bytesize
      while len > 0
        prefix = @romaji.byteslice(0, len)
        kana = ROMAJI_TABLE[prefix]
        if kana
          @romaji = @romaji.byteslice(len, @romaji.bytesize - len)
          return kana
        end
        len -= 1
      end

      # 'n' followed by non-vowel, non-n, non-y -> ん
      if @romaji.bytesize >= 2 && @romaji.byteslice(0, 1) == "n"
        c2 = @romaji.byteslice(1, 1)
        if N_FLUSH_CHARS.include?(c2)
          @romaji = @romaji.byteslice(1, @romaji.bytesize - 1)
          return "ん"
        end
      end

      nil
    end

    # Check if any ROMAJI_TABLE key starts with the given prefix
    def romaji_has_prefix?(prefix)
      ROMAJI_TABLE.each_key do |k|
        return true if k.byteslice(0, prefix.bytesize) == prefix
      end
      # Also allow 'n' alone (could become 'ん' or 'na', 'ni', etc.)
      return true if prefix == "n"
      false
    end

    # Flush pending 'n' as 'ん' and commit
    def flush_n(im)
      if @romaji == "n"
        kana = (@mode == :katakana) ? "ン" : "ん"
        im.commit(kana)
        @romaji = ""
      elsif @romaji.bytesize > 0
        im.commit(@romaji)
        @romaji = ""
      end
    end

    # Flush pending 'n' into @reading (for kanji mode)
    def flush_n_to_reading
      if @romaji == "n"
        @reading += "ん"
        @romaji = ""
      elsif @romaji.bytesize > 0
        @reading += @romaji
        @romaji = ""
      end
    end

    def flush_romaji(im)
      flush_n(im)
      im.set_preedit("")
    end

    # Convert hiragana string to katakana
    def hiragana_to_katakana(str)
      result = ""
      i = 0
      while i < str.bytesize
        byte = str.getbyte(i)
        if byte >= 0xE0 && (i + 2) < str.bytesize
          # 3-byte UTF-8 sequence
          b1 = byte
          b2 = str.getbyte(i + 1)
          b3 = str.getbyte(i + 2)
          cp = ((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
          # Hiragana range: U+3041 - U+3096
          if cp >= 0x3041 && cp <= 0x3096
            cp += KATA_OFFSET
            result += ((0xE0 | (cp >> 12)) & 0xFF).chr
            result += ((0x80 | ((cp >> 6) & 0x3F)) & 0xFF).chr
            result += ((0x80 | (cp & 0x3F)) & 0xFF).chr
          else
            result += str.byteslice(i, 3)
          end
          i += 3
        elsif byte >= 0xC0 && (i + 1) < str.bytesize
          result += str.byteslice(i, 2)
          i += 2
        else
          result += str.byteslice(i, 1)
          i += 1
        end
      end
      result
    end
  end
end
