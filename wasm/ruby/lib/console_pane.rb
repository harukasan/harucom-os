# Console output pane (replaces the static #out). props[:lines] is the buffered
# stdout/stderr lines; pre is not a funicular tag, so a div with a
# whitespace-pre-wrap class joins them for display.
class ConsolePane < Funicular::Component
  def render
    div(id: "out", class: "console") do
      (props[:lines] || []).join("\n")
    end
  end
end
