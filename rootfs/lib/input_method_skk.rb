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
      "." => "。", "," => "、",
      "[" => "「", "]" => "」",
      "zh" => "←", "zj" => "↓", "zk" => "↑", "zl" => "→",
      "z/" => "・", "z." => "…", "z," => "‥", "z-" => "〜",
      "z[" => "『", "z]" => "』",
    }

    # Characters that trigger 'n' -> 'ん' flush (not vowels and not 'n' or 'y')
    N_FLUSH_CHARS = "bcdfghjklmpqrstvwxz"

    # Hiragana -> Katakana offset (Unicode block difference)
    KATA_OFFSET = 0x60  # U+30A0 - U+3040

    USER_DICT_PATH = "/data/skk-user-dict.txt"

    def initialize
      @mode = :hiragana
      @romaji = ""       # romaji accumulation buffer
      @reading = ""      # kanji reading accumulation (hiragana)
      @okuri_prefix = nil  # okurigana consonant prefix (e.g. "m" for NoMu)
      @okuri_romaji = ""   # okurigana romaji accumulation
      @okuri_kana = ""     # completed okurigana kana
      @user_dict = {}      # reading => [candidate, ...]
      load_user_dict
    end

    # True when engine is in base state (no pending conversion)
    def idle?
      @mode == :hiragana && @romaji.bytesize == 0
    end

    def process(key, im)
      case @mode
      when :hiragana, :katakana
        process_kana(key, im)
      when :zenkaku
        process_zenkaku(key, im)
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
      when :zenkaku   then "[Ａ]"
      when :kanji     then "[あ]"
      when :candidate then "[あ]"
      end
    end

    # Return to hiragana mode from any sub-mode. Returns true if mode changed.
    def back_to_hiragana(im)
      return false if @mode == :hiragana
      if @mode == :kanji || @mode == :candidate
        reset(im)
      else
        @mode = :hiragana
        im.set_preedit("")
      end
      true
    end

    def reset(im)
      if @romaji.bytesize > 0
        im.commit(@romaji)
        @romaji = ""
      end
      if @mode == :kanji || @mode == :candidate
        im.commit(@reading) if @reading.bytesize > 0
        @reading = ""
        clear_okuri
        @mode = :hiragana
      end
      im.set_preedit("")
      im.clear_candidates
    end

    def register_word(reading, candidate)
      @user_dict[reading] ||= []
      @user_dict[reading].delete(candidate)
      @user_dict[reading].unshift(candidate)
      save_user_dict
    end

    private

    # ASCII 0x21..0x7E to full-width U+FF01..U+FF5E, space to U+3000
    def to_zenkaku(ch)
      b = ch.getbyte(0)
      if b == 0x20
        "\u3000"  # full-width space
      elsif b >= 0x21 && b <= 0x7E
        cp = 0xFF01 + (b - 0x21)
        buf = ""
        buf << ((0xEF).chr)
        buf << ((0x80 | ((cp >> 6) & 0x3F)).chr)
        buf << ((0x80 | (cp & 0x3F)).chr)
        buf
      else
        ch
      end
    end

    def process_zenkaku(key, im)
      return :passthrough unless key.printable?

      im.commit(to_zenkaku(key.to_s))
      :commit
    end

    def process_kana(key, im)
      # 'l' switches to ASCII mode (deactivate engine)
      # Skip when romaji buffer is "z" to allow zl -> → conversion
      if key.match?(:l, ctrl: false, shift: false) && @romaji != "z"
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

      # Shift+L: switch to full-width ASCII mode
      if ch == "L"
        flush_n(im)
        @mode = :zenkaku
        return :consumed
      end

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
      if key.to_s == " "
        flush_n_to_reading
        if @reading.bytesize > 0
          candidates = lookup(@reading)
          if candidates
            im.set_candidates(candidates, 0)
            im.set_preedit("▼" + candidates[0])
            @mode = :candidate
            return :consumed
          end
          # No candidates: enter register mode (unless already registering)
          if im.registering
            # Already registering: commit reading as-is
            im.commit(@reading)
          else
            im.start_register(@reading)
          end
          @reading = ""
          @romaji = ""
          @mode = :hiragana
        end
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

      # Shift+letter: start okurigana
      if key.shift?
        flush_n_to_reading
        if @reading.bytesize > 0
          @okuri_prefix = ch.downcase
          @okuri_romaji = @okuri_prefix
          @okuri_kana = ""
          candidates = lookup(@reading + @okuri_prefix)
          if candidates
            im.set_candidates(candidates, 0)
            im.set_preedit("▼" + candidates[0] + "*" + @okuri_romaji)
            @mode = :candidate
            return :consumed
          end
          @okuri_prefix = nil
          @okuri_romaji = ""
          im.set_preedit("▽" + @reading)
        end
        return :consumed
      end

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

      # During okurigana: accumulate romaji to complete the okurigana kana
      if @okuri_prefix && key.printable?
        ch = key.to_s
        @okuri_romaji += ch.downcase
        kana = try_okuri_conversion
        if kana
          @okuri_kana = kana
          confirm_candidate(im, candidates, idx)
          return :commit
        end
        # Still accumulating okurigana romaji
        im.set_preedit("▼" + candidates[idx] + "*" + @okuri_romaji)
        return :consumed
      end

      # Space: next candidate (wrap around)
      if key.to_s == " "
        if candidates
          idx = (idx + 1) % candidates.length
          im.set_candidates(candidates, idx)
          im.set_preedit("▼" + candidates[idx])
        end
        return :consumed
      end

      # 'x': previous candidate (wrap or back to kanji entry)
      if key.match?(:x, ctrl: false, shift: false)
        if idx > 0
          idx -= 1
          im.set_candidates(candidates, idx)
          im.set_preedit("▼" + candidates[idx])
        else
          @mode = :kanji
          clear_okuri
          im.clear_candidates
          im.set_preedit("▽" + @reading)
        end
        return :consumed
      end

      # Escape / Ctrl-G: cancel, back to kanji entry
      if key == Keyboard::ESCAPE || key.match?(:g, ctrl: true)
        @mode = :kanji
        clear_okuri
        im.clear_candidates
        im.set_preedit("▽" + @reading)
        return :consumed
      end

      # Enter: confirm current candidate
      if key == Keyboard::ENTER
        confirm_candidate(im, candidates, idx)
        return :commit
      end

      # Any other key: confirm candidate then reprocess
      if candidates && candidates[idx]
        confirm_candidate(im, candidates, idx)
        process_kana(key, im)
        return :commit
      end

      :passthrough
    end

    def confirm_candidate(im, candidates, idx)
      text = (candidates && candidates[idx]) ? candidates[idx] : ""
      text += @okuri_kana if @okuri_kana.bytesize > 0
      im.commit(text) if text.bytesize > 0
      @reading = ""
      @romaji = ""
      clear_okuri
      @mode = :hiragana
    end

    def clear_okuri
      @okuri_prefix = nil
      @okuri_romaji = ""
      @okuri_kana = ""
    end

    # Try to convert okurigana romaji buffer. Returns kana or nil.
    def try_okuri_conversion
      # Double consonant -> っ + keep second
      if @okuri_romaji.bytesize >= 2
        c1 = @okuri_romaji.byteslice(0, 1)
        c2 = @okuri_romaji.byteslice(1, 1)
        if c1 == c2 && c1 != "a" && c1 != "i" && c1 != "u" && c1 != "e" && c1 != "o" && c1 != "n"
          @okuri_romaji = @okuri_romaji.byteslice(1, @okuri_romaji.bytesize - 1)
          return "っ"
        end
      end

      len = @okuri_romaji.bytesize
      while len > 0
        prefix = @okuri_romaji.byteslice(0, len)
        kana = ROMAJI_TABLE[prefix]
        if kana
          @okuri_romaji = @okuri_romaji.byteslice(len, @okuri_romaji.bytesize - len)
          return kana
        end
        len -= 1
      end
      nil
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

    # Look up a reading in user dict first, then flash dict.
    # Returns Array of candidates, or nil.
    def lookup(reading)
      user = @user_dict[reading]
      flash = InputMethod.skk_lookup(reading)
      if user && flash
        # Merge: user candidates first, then flash (skip duplicates)
        merged = user.dup
        flash.each { |c| merged.push(c) unless merged.include?(c) }
        merged
      else
        user || flash
      end
    end

    def load_user_dict
      return unless File.exist?(USER_DICT_PATH)
      content = File.open(USER_DICT_PATH, "r") { |f| f.read }
      return unless content
      content.split("\n").each do |line|
        next if line.bytesize == 0
        reading, rest = line.split(" ", 2)
        next unless rest
        candidates = []
        rest.split("/").each do |c|
          candidates.push(c) if c.bytesize > 0
        end
        @user_dict[reading] = candidates if candidates.length > 0
      end
    end

    def save_user_dict
      content = ""
      @user_dict.each do |reading, candidates|
        content += reading + " /" + candidates.join("/") + "/\n"
      end
      File.open(USER_DICT_PATH, "w") { |f| f.write(content) }
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
