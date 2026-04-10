# InputMethod: Japanese input method dispatcher
#
# Sits between Keyboard#read_char and the application. Processes key events
# through the active engine (SKK or T-Code) and returns a result indicating
# whether the key was consumed, produced committed text, or should be passed
# through to the application unchanged.
#
# Usage:
#   result = $ime.process(key)
#   case result
#   when :commit      then buffer.put($ime.take_committed)
#   when :consumed    then # redraw preedit only
#   when :passthrough then # handle key normally
#   end

class InputMethod
  # InputMethod class methods (dict_available?, skk_lookup, tcode_lookup)
  # are defined in C (picoruby-input-method gem).

  attr_reader :preedit         # String: uncommitted text shown at cursor
  attr_reader :candidates      # Array of String, or nil
  attr_reader :candidate_index # Integer: currently selected candidate

  PREEDIT_ATTR   = 0xA0  # bright green on black
  CANDIDATE_ATTR = 0xD0  # bright magenta on black

  def initialize
    @engine = nil          # nil = ASCII direct input
    @skk = nil             # lazy initialized
    @tcode = nil           # lazy initialized
    @preedit = ""
    @committed = ""
    @candidates = nil
    @candidate_index = 0
    @engine_name = nil     # :skk, :tcode, or nil
  end

  # Process a Keyboard::Key. Returns :passthrough, :consumed, or :commit.
  def process(key)
    # Ctrl-J: activate SKK hiragana mode, or return to hiragana from sub-modes.
    # If already in hiragana, deactivate SKK.
    if key.match?(:j, ctrl: true)
      if @engine_name == :skk
        unless @engine.back_to_hiragana(self)
          set_engine(nil)
        end
      else
        set_engine(:skk)
      end
      return :consumed
    end

    # Ctrl-\: cycle input methods (nil -> :skk -> :tcode -> nil)
    if key.ctrl? && key.name.to_s == "\\"
      cycle_engine
      return :consumed
    end

    return :passthrough unless @engine
    @engine.process(key, self)
  end

  # Retrieve and clear committed text
  def take_committed
    text = @committed
    @committed = ""
    text
  end

  # Mode label for display: "[A]", "[あ]", "[ア]", "[漢]"
  def mode_label
    return nil unless @engine
    @engine.mode_label
  end

  # Switch engine: :skk, :tcode, or nil
  # Returns true if the engine was activated, false if unavailable.
  def set_engine(name)
    # T-Code requires a dictionary in flash
    if name == :tcode && !InputMethod.dict_available?
      return false
    end

    # Commit any pending input from current engine
    if @engine
      @engine.reset(self)
    end

    @engine_name = name
    case name
    when :skk
      @skk ||= InputMethod::SKK.new
      @engine = @skk
    when :tcode
      @tcode ||= InputMethod::TCode.new
      @engine = @tcode
    else
      @engine = nil
      @preedit = ""
      @candidates = nil
    end
    true
  end

  # Cycle: nil -> :skk -> :tcode -> nil
  # Skips engines that are unavailable (e.g. T-Code without dictionary).
  def cycle_engine
    case @engine_name
    when nil
      set_engine(:skk)
    when :skk
      set_engine(:tcode) || set_engine(nil)
    when :tcode
      set_engine(nil)
    end
  end

  # Called by engines to commit text
  def commit(text)
    @committed += text
    @preedit = ""
    @candidates = nil
    @candidate_index = 0
  end

  # Called by engines to update preedit
  def set_preedit(text)
    @preedit = text
  end

  # Called by engines to set candidates
  def set_candidates(list, index)
    @candidates = list
    @candidate_index = index
  end

  # Called by engines to clear candidates
  def clear_candidates
    @candidates = nil
    @candidate_index = 0
  end
end
