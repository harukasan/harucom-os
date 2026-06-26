# StatusPanel: a small VM readout (DVI frame count, audio underruns). It shows
# how a Panel consumes the other Engine events. Frame ticks ~60/s, so it patches
# only every 30th frame to keep the UI task light; underruns change rarely.
class StatusPanel < Harucom::UI::Panel
  title "Status"
  slug "status"
  order 40

  styles do
    pane "font-mono text-xs h-full overflow-auto p-3 text-fg"
    row "flex gap-2 py-0.5"
    label "w-20 text-fg-dim"
  end

  def initialize_state
    { frame: Harucom.engine.frame, underruns: Harucom.engine.underruns }
  end

  def component_mounted
    on_engine(:frame) { |f| patch(frame: f) if (f % 30) == 0 }
    on_engine(:audio) { |u| patch(underruns: u) }
  end

  def stat(name, value)
    div(class: s.row) do
      span(class: s.label) { name }
      span { value }
    end
  end

  def render
    div(id: "status", class: s.pane) do
      stat("frame", state.frame.to_s)
      stat("underruns", state.underruns.to_s)
    end
  end
end
