# Harucom::UI::App: the root layout. The OS canvas (Screen) is always shown; the
# Panels host docks below it (dock=:bottom) or beside it (dock=:right), like a
# browser devtools panel. App owns the dock state and passes a callback down to
# Panels so the dock buttons can flip it. Screen and Panels are preserved across
# the re-render so the canvas, active tab, and console history survive a switch.

module Harucom
  module UI
    class App < Component
      styles do
        col "h-screen w-screen bg-base text-fg flex flex-col overflow-hidden"
        row "h-screen w-screen bg-base text-fg flex flex-row overflow-hidden"
        main "flex-1 grid place-items-center p-4 min-h-0 min-w-0 overflow-hidden"
        dock_bottom "h-64 border-t border-tab-border overflow-hidden bg-panel-bg"
        dock_right "w-96 border-l border-tab-border overflow-hidden bg-panel-bg"
      end

      def initialize_state
        { dock: :bottom }
      end

      def render
        bottom = state.dock == :bottom
        div(class: bottom ? s.col : s.row) do
          div(class: s.main) do
            component(Screen, { preserve: true })
          end
          div(class: bottom ? s.dock_bottom : s.dock_right) do
            component(Panels, { preserve: true, on_dock: ->(pos) { patch(dock: pos) } })
          end
        end
      end
    end
  end
end
