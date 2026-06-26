# ConsolePanel: stdout/stderr log (the former #out). The line buffer lives in the
# Engine, so the history is intact even after the panel was unmounted; this panel
# reads the snapshot on mount and re-reads it on each :print.
class ConsolePanel < Harucom::UI::Panel
  title "Console"
  slug "console"
  order 10

  styles do
    pane "bg-black text-term-green font-mono text-xs h-full overflow-y-auto p-2 whitespace-pre-wrap"
  end

  def initialize_state
    { lines: Harucom.engine.console_lines.dup }
  end

  def component_mounted
    on_engine(:print) { |lines| patch(lines: lines) }
  end

  def render
    div(id: "console", class: s.pane) do
      state.lines.join("\n")
    end
  end
end
