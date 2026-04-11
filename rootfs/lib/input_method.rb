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
  # are defined in C (harucom-os-dict gem).

  attr_reader :preedit         # String: uncommitted text shown at cursor
  attr_reader :candidates      # Array of String, or nil
  attr_reader :candidate_index # Integer: currently selected candidate
  attr_reader :registering     # true when in word registration mode

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
    @registering = false
    @register_reading = nil
    @register_buf = ""
  end

  # Process a Keyboard::Key. Returns :passthrough, :consumed, or :commit.
  def process(key)
    # During registration in base state: Enter confirms (if buffer non-empty),
    # Escape cancels, Backspace deletes from register buffer
    if @registering && engine_idle?
      if key == Keyboard::ENTER
        if @register_buf.bytesize > 0
          return finish_register
        else
          cancel_register
          return :consumed
        end
      end
      if key == Keyboard::ESCAPE || key.match?(:g, ctrl: true)
        cancel_register
        return :consumed
      end
      if key == Keyboard::BSPACE
        if @register_buf.bytesize > 0
          pos = Editor.prev_char_byte_pos(@register_buf, @register_buf.bytesize)
          @register_buf = @register_buf.byteslice(0, pos)
          update_register_preedit
        end
        return :consumed
      end
    end

    # Ctrl-J: activate SKK hiragana mode, or return to hiragana from sub-modes.
    # If already in hiragana, deactivate SKK (unless registering).
    if key.match?(:j, ctrl: true)
      if @engine_name == :skk
        unless @engine.back_to_hiragana(self)
          # Already in hiragana: deactivate unless registering
          set_engine(nil) unless @registering
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
    result = @engine.process(key, self)
    # During registration, nothing leaks to the application
    if @registering && (result == :commit || result == :passthrough)
      result = :consumed
    end
    result
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
      @preedit = "" unless @registering
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

  # Called by engines to commit text.
  # During registration, text accumulates in the register buffer.
  def commit(text)
    if @registering
      @register_buf += text
      update_register_preedit
    else
      @committed += text
      @preedit = ""
      @candidates = nil
      @candidate_index = 0
    end
  end

  # Called by engines to update preedit
  def set_preedit(text)
    if @registering
      @preedit = "[登録: " + @register_reading + "] " + @register_buf + text
    else
      @preedit = text
    end
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

  # Enter word registration mode.
  # Called by SKK when no candidates are found for a reading.
  def start_register(reading)
    return if @registering  # prevent nesting
    @registering = true
    @register_reading = reading
    @register_buf = ""
    update_register_preedit
  end

  private

  def engine_idle?
    return true unless @engine
    return true unless @engine.respond_to?(:idle?)
    @engine.idle?
  end

  def update_register_preedit
    @preedit = "[登録: " + @register_reading + "] " + @register_buf
  end

  def finish_register
    if @register_buf.bytesize > 0
      # Save to SKK user dictionary regardless of current engine
      @skk.register_word(@register_reading, @register_buf) if @skk
      @committed += @register_buf
    end
    @registering = false
    @register_reading = nil
    @register_buf = ""
    @preedit = ""
    :commit
  end

  def cancel_register
    @registering = false
    @register_reading = nil
    @register_buf = ""
    @preedit = ""
  end
end
