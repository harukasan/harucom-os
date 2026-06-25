# On-screen D-pads (replaces pads.js). Press/release call the Engine bridge
# directly (Shell -> Engine is a safe direct call). dir: RIGHT=0 UP=1 DOWN=2
# LEFT=3, laid out as a cross.
class Pads < Funicular::Component
  # label, dir, grid column, grid row (a cross: up / left right / down).
  LAYOUT = [["↑", 1, 2, 1], ["←", 3, 1, 2], ["→", 0, 3, 2], ["↓", 2, 2, 3]]

  def bridge
    b = JS.global[:__harucomBridge]
    b.is_a?(JS::Object) ? b : nil
  end

  def press(pad, dir)
    b = bridge
    return unless b
    b.startAudio # a pad tap is also the audio user-gesture
    b.setPad(pad, dir, true)
  end

  def release(pad, dir)
    b = bridge
    return unless b
    b.setPad(pad, dir, false)
  end

  # A single direction button. The lambdas capture pad/dir from these arguments
  # (fresh per call), so they are correct regardless of the build loop.
  def pad_button(pad, label, dir, col, row)
    button(class: "padbtn",
           style: "grid-column:#{col};grid-row:#{row}",
           onpointerdown: -> { press(pad, dir) },
           onpointerup: -> { release(pad, dir) },
           onpointerleave: -> { release(pad, dir) }) do
      label
    end
  end

  def render_pad(pad)
    div(class: "pad") do
      i = 0
      while i < LAYOUT.length
        row = LAYOUT[i]
        pad_button(pad, row[0], row[1], row[2], row[3])
        i += 1
      end
    end
  end

  def render
    div(id: "pads", class: "pads") do
      pad = 0
      while pad < 2
        render_pad(pad)
        pad += 1
      end
    end
  end
end
