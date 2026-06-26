# PadsPanel: the two on-screen D-pads (the former #pads). Press/release call the
# Engine directly (UI -> Engine is a safe direct call). The pressed highlight is
# the CSS :active state (active:bg-pad-on), so no per-button Ruby state is needed.
# dir: RIGHT=0 UP=1 DOWN=2 LEFT=3, laid out as a cross.
class PadsPanel < Harucom::UI::Panel
  title "Pads"
  slug "pads"
  order 30

  # label, dir, grid column, grid row (a cross: up / left right / down).
  LAYOUT = [["↑", 1, 2, 1], ["←", 3, 1, 2], ["→", 0, 3, 2], ["↓", 2, 2, 3]]

  styles do
    wrap "flex gap-8 p-2"
    pad "grid gap-0.5"
    btn "w-10 h-10 rounded bg-pad text-fg text-lg select-none touch-none border border-gray-600 active:bg-pad-on"
  end

  def press(pad, dir)
    engine.start_audio # a pad tap is also the audio user-gesture
    engine.pad_set(pad, dir, true)
  end

  def release(pad, dir)
    engine.pad_set(pad, dir, false)
  end

  # A single direction button. The lambdas capture pad/dir from these arguments
  # (fresh per call), so they are correct regardless of the build loop.
  def pad_button(pad, label, dir, col, row)
    button(class: s.btn,
           style: "grid-column:#{col};grid-row:#{row}",
           onpointerdown: -> { press(pad, dir) },
           onpointerup: -> { release(pad, dir) },
           onpointerleave: -> { release(pad, dir) }) do
      label
    end
  end

  def render_pad(pad)
    div(class: s.pad, style: "grid-template-columns:repeat(3,2.5rem);grid-auto-rows:2.5rem") do
      i = 0
      while i < LAYOUT.length
        r = LAYOUT[i]
        pad_button(pad, r[0], r[1], r[2], r[3])
        i += 1
      end
    end
  end

  def render
    div(id: "pads", class: s.wrap) do
      pad = 0
      while pad < 2
        render_pad(pad)
        pad += 1
      end
    end
  end
end
