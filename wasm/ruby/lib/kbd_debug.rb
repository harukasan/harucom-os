# Keyboard debug readout (replaces the static #kbddbg). props[:info] is the last
# key / HID / held string the Engine reported.
class KbdDebug < Funicular::Component
  def render
    div(id: "kbddbg", class: "kbddbg") do
      (props[:info] || "").to_s
    end
  end
end
