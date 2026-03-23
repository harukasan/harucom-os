# KeyboardInput: $stdin compatible input from USB keyboard
#
# Delegates gets/readline to LineEditor for line editing support.
# Assign to $stdin to make Kernel#gets work with USB keyboard + DVI.

class KeyboardInput
  def initialize(line_editor:)
    @line_editor = line_editor
  end

  def gets(sep = "\n")
    line = @line_editor.readline("")
    return nil unless line
    line + sep
  end

  def readline(sep = "\n")
    line = gets(sep)
    raise EOFError, "end of file reached" unless line
    line
  end

  def read_nonblock(maxlen)
    nil
  end
end
