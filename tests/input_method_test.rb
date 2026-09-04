require "picotest"
require "input_method"

# The dispatcher hands a key to the active engine and reports what happened
# with it. An engine can commit text and still hand the key on, which is what
# SKK does for a non-printable key and what T-Code does for a key it cannot
# pair, so a caller has to take committed text on every result rather than on
# :commit alone. Reading it on :commit alone leaves the text waiting for the
# next conversion, where it lands wherever the cursor has moved to since.
class InputMethodTest < Picotest::Test
  # Flushes a composition and hands the key on, the way an engine does when a
  # key interrupts one.
  class FlushingEngine
    def process(key, im)
      im.commit("ん")
      :passthrough
    end

    def reset(im)
    end

    def idle?
      true
    end

    def mode_label
      "[test]"
    end
  end

  # Enough of Keyboard::Key for the dispatcher to route a plain letter.
  class Key
    attr_reader :name

    def initialize(name = :a, char = "a", ctrl: false)
      @name = name
      @char = char
      @ctrl = ctrl
    end

    def ctrl?
      @ctrl
    end

    def printable?
      !@ctrl && @char != nil
    end

    def match?(name = nil, ctrl: nil, shift: nil, alt: nil, super_key: nil)
      return false if name != nil && @name != name
      return false if ctrl != nil && @ctrl != ctrl
      true
    end

    def to_s
      @char
    end
  end

  def flushing_ime
    ime = InputMethod.new
    ime.instance_variable_set(:@engine, FlushingEngine.new)
    ime
  end

  def test_committed_text_survives_a_passthrough
    ime = flushing_ime
    assert_equal :passthrough, ime.process(Key.new)
    assert_equal "ん", ime.take_committed
  end

  def test_taking_committed_text_clears_it
    ime = flushing_ime
    ime.process(Key.new)
    assert_equal "ん", ime.take_committed
    assert_equal "", ime.take_committed
  end

  def test_a_key_reaches_the_application_when_no_engine_is_active
    ime = InputMethod.new
    assert_equal :passthrough, ime.process(Key.new)
    assert_equal "", ime.take_committed
  end
end
