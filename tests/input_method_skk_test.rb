require "picotest"
require "input_method_skk"

# SKK holds a composition across keystrokes: romaji waiting to become kana,
# and in kanji mode a reading waiting for a conversion. A key that carries no
# character of its own ends that composition. The engine commits what it has
# and consumes the key, so the key never acts on a buffer the flush has just
# changed and the text cannot resurface at a position the cursor moved to.
class InputMethodSkkTest < Picotest::Test
  # Stands in for InputMethod, which engines call back to commit text and to
  # update the preedit.
  class Composer
    attr_reader :preedit, :committed

    def initialize
      @preedit = ""
      @committed = ""
    end

    def commit(text)
      @committed += text
      @preedit = ""
    end

    def set_preedit(text)
      @preedit = text
    end

    def set_candidates(list, index)
    end

    def clear_candidates
    end

    def registering
      false
    end

    def start_register(reading)
      @committed += "[register #{reading}]"
    end
  end

  def setup
    InputMethod.skk_entries = { "かん" => ["感", "館"] }
    @skk = InputMethod::SKK.new
    @composer = Composer.new
  end

  def type(chars)
    i = 0
    while i < chars.length
      ch = chars[i]
      @skk.process(Keyboard.key(ch.downcase.to_sym, ch), @composer)
      i += 1
    end
  end

  def test_romaji_becomes_kana_as_it_completes
    type("ka")
    assert_equal "か", @composer.committed
  end

  def test_an_arrow_key_ends_a_kana_composition
    type("n")
    assert_equal "n", @composer.preedit
    assert_equal :commit, @skk.process(Keyboard::LEFT, @composer)
    assert_equal "ん", @composer.committed
    assert_equal "", @composer.preedit
  end

  def test_an_arrow_key_with_nothing_pending_reaches_the_application
    assert_equal :passthrough, @skk.process(Keyboard::LEFT, @composer)
    assert_equal "", @composer.committed
  end

  def test_an_arrow_key_confirms_a_kanji_reading
    @skk.process(Keyboard.key(:k, "K", shift: true), @composer)
    type("an")
    assert_equal :commit, @skk.process(Keyboard::LEFT, @composer)
    assert_equal "かん", @composer.committed
    assert_equal "", @composer.preedit
    assert @skk.idle?
  end
end
