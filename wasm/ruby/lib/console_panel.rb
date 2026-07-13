# ConsolePanel: stdout/stderr log (the former #out). The line buffer lives in the
# Engine, so the history is intact even after the panel was unmounted; this panel
# reads the snapshot on mount and re-reads it on each :print. It keeps the view
# pinned to the bottom while the user has not scrolled up to read back.
class ConsolePanel < Harucom::UI::Panel
  title "Console"
  slug "console"
  order 10

  styles do
    pane "bg-base text-console font-mono text-xs leading-relaxed h-full overflow-y-auto p-2 whitespace-pre-wrap break-all"
  end

  def initialize_state
    { lines: Harucom.engine.console_lines.dup }
  end

  def component_mounted
    on_engine(:print) { |lines| patch(lines: lines) }
  end

  # Auto-scroll to the newest line, but only when the view is already near the
  # bottom (so reading back through history is not yanked away).
  def component_updated
    el = JS.document.getElementById("console")
    return unless el
    gap = el[:scrollHeight].to_i - el[:scrollTop].to_i - el[:clientHeight].to_i
    el[:scrollTop] = el[:scrollHeight] if gap < 40
  end

  def render
    div(id: "console", class: s.pane) do
      state.lines.join("\n")
    end
  end
end
