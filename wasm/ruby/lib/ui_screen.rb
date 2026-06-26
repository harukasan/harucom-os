# Harucom::UI::Screen: the safe leaf that holds the Engine-owned DVI canvas. It
# renders an empty host once and moves the existing <canvas id="screen"> into it
# on mount. Screen never patches its own state, so it never re-renders and never
# lets funicular recreate the canvas (which would drop the 2D context). With
# preserve: true at the App level the instance survives dock switches too.

module Harucom
  module UI
    class Screen < Component
      styles do
        host "inline-block leading-none"
      end

      def render
        div(id: "screen-host", class: s.host)
      end

      def component_mounted
        canvas = JS.document.getElementById("screen")
        dom_element.appendChild(canvas) if canvas
      end
    end
  end
end
