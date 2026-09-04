require "picotest"
require "input_method_tcode"

# InputMethod::TCode turns two keystrokes into one character through the
# 40x40 table in the flash dictionary. The table itself comes from
# harucom-os-dict. These tests install a small one through the stub in
# tests/stubs.rb and cover the input behavior around it: stroke pairing,
# stroke order, the preedit, the timeout, and the keys the layout leaves out.
class InputMethodTCodeTest < Picotest::Test
  POSITIONS = InputMethod::TCode::KEY_POSITIONS

  # A key event as Keyboard#read_char delivers it. TCode asks a key only
  # whether it is printable and which character it carries.
  class Key
    def initialize(char, printable = true, name = nil, ctrl: false, shift: false, alt: false, super_key: false)
      @char = char
      @printable = printable
      @name = name
      @ctrl = ctrl
      @shift = shift
      @alt = alt
      @super = super_key
    end

    def printable?
      @printable
    end

    # Same shape as Keyboard::Key#match?: an argument left out is not checked,
    # so a test can tell Backspace from Shift-Backspace.
    def match?(name = nil, ctrl: nil, shift: nil, alt: nil, super_key: nil)
      return false if name  != nil && @name  != name
      return false if ctrl  != nil && @ctrl  != ctrl
      return false if shift != nil && @shift != shift
      return false if alt   != nil && @alt   != alt
      return false if super_key != nil && @super != super_key
      true
    end

    def to_s
      @char
    end
  end

  # Stands in for InputMethod, which engines call back to commit text and
  # to update the preedit.
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
  end

  def setup
    Machine.millis = 0
    # T-Code writes the full stop as "hf" and the comma as "jd". The
    # reversed pairs hold other characters, so a table read in the wrong
    # stroke order surfaces as a wrong character instead of no match.
    InputMethod.tcode_table = {
      index("hf") => "。",
      index("fh") => "愛",
      index("jd") => "、",
      index("dj") => "味",
    }
    @tcode = InputMethod::TCode.new
    @composer = Composer.new
  end

  def index(strokes)
    POSITIONS[strokes[0]] * POSITIONS.size + POSITIONS[strokes[1]]
  end

  def press(char, printable = true, name = nil, ctrl: false, shift: false, alt: false, super_key: false)
    key = Key.new(char, printable, name, ctrl: ctrl, shift: shift, alt: alt, super_key: super_key)
    @tcode.process(key, @composer)
  end

  def press_special(name, ctrl: false, shift: false, alt: false, super_key: false)
    press(nil, false, name, ctrl: ctrl, shift: shift, alt: alt, super_key: super_key)
  end

  def test_two_strokes_commit_one_character
    assert_equal :consumed, press("h")
    assert_equal :commit, press("f")
    assert_equal "。", @composer.committed
  end

  def test_the_first_stroke_shows_as_preedit_until_the_pair_completes
    press("h")
    assert_equal "h", @composer.preedit
    assert_equal "", @composer.committed
    press("f")
    assert_equal "", @composer.preedit
  end

  def test_the_stroke_order_selects_the_entry
    press("f")
    press("h")
    assert_equal "愛", @composer.committed
  end

  def test_consecutive_pairs_keep_their_order
    press("h")
    press("f")
    press("j")
    press("d")
    assert_equal "。、", @composer.committed
  end

  def test_idle_reports_whether_a_stroke_is_pending
    assert @tcode.idle?
    press("h")
    assert_false @tcode.idle?
    press("f")
    assert @tcode.idle?
  end

  def test_a_pair_completed_just_before_the_timeout_still_converts
    press("h")
    Machine.millis = InputMethod::TCode::TIMEOUT_MS - 1
    assert_equal :commit, press("f")
    assert_equal "。", @composer.committed
  end

  def test_the_timeout_commits_the_first_stroke_as_plain_text
    press("h")
    Machine.millis = InputMethod::TCode::TIMEOUT_MS
    assert_equal :commit, press("f")
    assert_equal "h", @composer.committed
    assert_equal "f", @composer.preedit
  end

  def test_a_key_after_the_timeout_starts_a_new_pair
    press("h")
    Machine.millis = InputMethod::TCode::TIMEOUT_MS
    press("f")
    press("h")
    assert_equal "h愛", @composer.committed
  end

  def test_a_pair_missing_from_the_table_commits_both_keys
    press("a")
    assert_equal :commit, press("s")
    assert_equal "as", @composer.committed
  end

  def test_a_key_outside_the_layout_passes_through
    assert_equal :passthrough, press("!")
    assert_equal "", @composer.committed
  end

  # A key off the layout still stands for its own character, so it goes in
  # behind the stroke it ended.
  def test_a_key_outside_the_layout_commits_behind_the_stroke
    press("h")
    assert_equal :commit, press("!")
    assert_equal "h!", @composer.committed
    assert_equal "", @composer.preedit
    assert @tcode.idle?
  end

  def test_a_non_printable_key_passes_through
    assert_equal :passthrough, press("\e", false)
  end

  # A key with no character of its own ends the pair and is consumed, the way
  # an IME consumes the key that ends a composition. It never reaches the
  # application, so it cannot act on a buffer this flush has just changed.
  def test_a_non_printable_key_ends_the_pair_and_is_consumed
    press("h")
    assert_equal :commit, press_special(:enter)
    assert_equal "h", @composer.committed
    assert_equal "", @composer.preedit
    assert @tcode.idle?
  end

  def test_backspace_takes_back_a_pending_stroke
    press("h")
    assert_equal :consumed, press_special(:bspace)
    assert_equal "", @composer.committed
    assert_equal "", @composer.preedit
    assert @tcode.idle?
  end

  def test_backspace_without_a_pending_stroke_passes_through
    assert_equal :passthrough, press_special(:bspace)
    assert_equal "", @composer.committed
  end

  # Backspace with a modifier is a different key, so it does not cancel. It
  # ends the pair like any other key with no character of its own.
  def test_modified_backspace_ends_the_pair_instead_of_cancelling
    press("h")
    assert_equal :commit, press_special(:bspace, shift: true)
    assert_equal "h", @composer.committed
  end

  def test_super_backspace_does_not_cancel_either
    press("h")
    assert_equal :commit, press_special(:bspace, super_key: true)
    assert_equal "h", @composer.committed
  end

  def test_modified_escape_does_not_cancel
    press("h")
    assert_equal :commit, press_special(:escape, alt: true)
    assert_equal "h", @composer.committed
  end

  def test_escape_abandons_a_pending_stroke
    press("h")
    assert_equal :consumed, press_special(:escape)
    assert_equal "", @composer.committed
    assert_equal "", @composer.preedit
    assert @tcode.idle?
  end

  def test_ctrl_g_abandons_a_pending_stroke
    press("h")
    assert_equal :consumed, press(nil, false, :g, ctrl: true)
    assert_equal "", @composer.committed
    assert @tcode.idle?
  end

  def test_reset_commits_a_pending_stroke
    press("h")
    @tcode.reset(@composer)
    assert_equal "h", @composer.committed
    assert_equal "", @composer.preedit
    assert @tcode.idle?
  end

  def test_mode_label
    assert_equal "[漢]", @tcode.mode_label
  end
end
