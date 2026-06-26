# Harucom::UI::App: the root layout. The Panels host appears in one of three modes:
#   :undocked (default) a normal top-anchored page: the canvas sits a fixed gap
#            from the top, then a fixed 40px gap, then the panel box (resized
#            natively by its bottom-right corner via CSS resize). The page scrolls.
#   :bottom  a full-height app with a full-width dock below the centered canvas,
#            resized by the top-edge splitter.
#   :right   like :bottom but the dock is beside the canvas, resized by the left edge.
# App owns the dock mode and the edge-dock width/height. The canvas (Screen) is
# wrapped in a div at child index 0 in every mode so it is preserved across a
# switch and keeps its 2D context.
#
# Edge-dock resize drags imperatively: pointermove writes the dock element's
# inline size directly (no per-move re-render) and pointerup commits to state.
# The undocked box needs no Ruby state for its size: CSS resize keeps it in the
# DOM, clamped by the .undock-box min/max rules in app.css.

module Harucom
  module UI
    class App < Component
      MIN = 120
      MAX = 900

      styles do
        # Undocked: a normal, scrollable page anchored at the top.
        page "min-h-screen w-full bg-base text-fg flex flex-col items-center pt-8 pb-8"
        page_main "shrink-0"
        undock_box "undock-box mt-10 border border-border rounded-md bg-panel-bg flex flex-col"
        # Docked: a full-height app, canvas centered, dock filling the rest.
        col "h-screen w-screen bg-base text-fg flex flex-col overflow-hidden"
        row "h-screen w-screen bg-base text-fg flex flex-row overflow-hidden"
        main "flex-1 grid place-items-center p-4 min-h-0 min-w-0 overflow-hidden"
        grip_h "h-1.5 shrink-0 bg-border hover:bg-accent cursor-row-resize touch-none"
        grip_v "w-1.5 shrink-0 bg-border hover:bg-accent cursor-col-resize touch-none"
        dock_bottom "border-t border-border overflow-hidden bg-panel-bg shrink-0"
        dock_right "border-l border-border overflow-hidden bg-panel-bg shrink-0"
      end

      def initialize_state
        { dock: :undocked, w: 384, h: 256 } # w: right-dock width, h: bottom-dock height
      end

      def render
        state.dock == :undocked ? render_undocked : render_docked
      end

      # Undocked: top-anchored page, fixed 40px gap (mt-10) between canvas and box.
      # The box resizes via CSS (no JS); min/max are in app.css (.undock-box).
      def render_undocked
        div(class: s.page) do
          div(class: s.page_main) do
            component(Screen, { preserve: true })
          end
          div(class: s.undock_box) do
            component(Panels, { preserve: true, on_dock: dock_cb })
          end
        end
      end

      # Docked: centered canvas with a full-width (bottom) or full-height (right)
      # dock and an edge splitter.
      def render_docked
        bottom = state.dock == :bottom
        div(class: bottom ? s.col : s.row) do
          div(class: s.main) do
            component(Screen, { preserve: true })
          end
          # style: "" so that when this div reuses the undocked box's DOM node
          # (same index), the diff clears the inline width/height that CSS resize
          # left behind (otherwise the splitter inherits that size and breaks).
          div(class: bottom ? s.grip_h : s.grip_v, style: "",
              onpointerdown: ->(e) { resize_start(e) },
              onpointermove: ->(e) { resize_move(e) },
              onpointerup: ->(e) { resize_end(e) },
              onpointercancel: ->(e) { resize_end(e) })
          div(id: "dock", class: bottom ? s.dock_bottom : s.dock_right,
              style: bottom ? "height:#{clamp(state.h)}px" : "width:#{clamp(state.w)}px") do
            component(Panels, { preserve: true, on_dock: dock_cb })
          end
        end
      end

      def dock_cb
        ->(pos) { patch(dock: pos) }
      end

      def resize_start(e)
        e.preventDefault rescue nil
        @resizing = true
        @bottom = state.dock == :bottom
        @start = (@bottom ? e.clientY : e.clientX).to_i
        @base = @bottom ? state.h : state.w
        @size = @base
        e.target.setPointerCapture(e.pointerId.to_i) rescue nil
      end

      def resize_move(e)
        return unless @resizing
        pos = (@bottom ? e.clientY : e.clientX).to_i
        @size = clamp(@base + (@start - pos)) # drag the inner edge toward the canvas to grow
        dock = JS.document.getElementById("dock")
        dock.setAttribute("style", @bottom ? "height:#{@size}px" : "width:#{@size}px") if dock
      end

      def resize_end(e)
        return unless @resizing
        @resizing = false
        e.target.releasePointerCapture(e.pointerId.to_i) rescue nil
        patch(@bottom ? { h: @size } : { w: @size })
      end

      def clamp(n)
        return MIN if n < MIN
        return MAX if n > MAX
        n
      end
    end
  end
end
