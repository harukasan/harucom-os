class Keyboard
  class Key
    attr_reader :name   # Symbol: :a, :enter, :up, etc. (always lowercase)
    attr_reader :char   # String or nil: "a", "A", "!" (nil for Ctrl or special keys)

    def initialize(name, char, ctrl: false, shift: false, alt: false, super_key: false)
      @name = name
      @char = char
      @ctrl = ctrl
      @shift = shift
      @alt = alt
      @super = super_key
    end

    # Modifier predicates
    def ctrl?;  @ctrl;  end
    def shift?; @shift; end
    def alt?;   @alt;   end
    def super?; @super; end

    # Match against name and/or modifiers.
    # Only specified parameters are checked; nil parameters are ignored.
    #
    #   key.match?(:c, ctrl: true)   # Ctrl-C
    #   key.match?(:enter)           # Enter (any modifiers)
    #   key.match?(:a, ctrl: false)  # 'a' without Ctrl
    #
    def match?(name = nil, ctrl: nil, shift: nil, alt: nil, super_key: nil)
      return false if name      != nil && @name  != name
      return false if ctrl      != nil && @ctrl  != ctrl
      return false if shift     != nil && @shift != shift
      return false if alt       != nil && @alt   != alt
      return false if super_key != nil && @super != super_key
      true
    end

    # Printable character check.
    # Returns true for regular characters without Ctrl modifier.
    def printable?
      @char != nil && !@ctrl
    end

    # Returns the printable character, or nil for non-printable keys.
    def to_s
      @char
    end

    # Returns the input form that Editor::Buffer#put accepts:
    # String for printable characters, uppercase Symbol for special keys.
    def to_buffer_input
      if printable?
        @char
      else
        BUFFER_SYMBOL_MAP[@name]
      end
    end

    # Returns the ANSI escape sequence representation.
    def to_ansi
      if @ctrl && @name.is_a?(Symbol) && @name.to_s.bytesize == 1
        ((@name.to_s.getbyte(0) - 0x60) & 0x1F).chr
      elsif @char
        @char
      else
        ANSI_MAP[@name]
      end
    end

    def inspect
      parts = []
      parts << "Ctrl" if @ctrl
      parts << "Shift" if @shift
      parts << "Alt" if @alt
      parts << "Super" if @super
      parts << (@char ? @char.inspect : @name.to_s)
      "#<Key #{parts.join("-")}>"
    end

    ANSI_MAP = {
      enter: "\r",
      bspace: "\x7F",
      tab: "\t",
      escape: "\e",
      up: "\e[A",
      down: "\e[B",
      right: "\e[C",
      left: "\e[D",
      home: "\e[H",
      end: "\e[F",
      insert: "\e[2~",
      delete: "\e[3~",
      pageup: "\e[5~",
      pagedown: "\e[6~",
    }

    BUFFER_SYMBOL_MAP = {
      enter: :ENTER,
      bspace: :BSPACE,
      tab: :TAB,
      up: :UP,
      down: :DOWN,
      left: :LEFT, right: :RIGHT, home: :HOME,
    }
  end
end
