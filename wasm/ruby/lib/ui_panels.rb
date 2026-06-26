# Harucom::UI::Panels: the devtools-style host. It draws a tab bar (one tab per
# registered Panel, ordered) plus dock-position buttons, and renders the active
# Panel below. Panels self-register through Harucom::UI::Panel.inherited, so this
# host needs no list of them.

module Harucom
  module UI
    class Panels < Component
      def self.register(panel)
        list << panel unless list.include?(panel)
      end

      def self.list
        @list ||= []
      end

      def self.sorted
        # mruby Array has no sort_by, so compare with the block form.
        list.sort { |a, b| (a.order || 999) <=> (b.order || 999) }
      end

      styles do
        bar "flex items-stretch border-b border-tab-border bg-panel-bg"
        tabs "flex overflow-x-auto"
        tab base: "px-3 py-1 text-xs cursor-pointer text-tab-inactive hover:text-fg whitespace-nowrap border-b-2 border-transparent",
            active: "text-tab-active border-tab-border"
        dockbtn "px-2 text-tab-inactive hover:text-fg cursor-pointer leading-none"
        body "flex-1 overflow-auto bg-panel-bg min-h-0"
      end

      def initialize_state
        first = self.class.sorted.first
        { active: first ? first.slug : nil }
      end

      # The dock buttons report a position up to the App, which owns the dock
      # state (state flows down via props, events flow up via the callback).
      def dock(pos)
        cb = props[:on_dock]
        cb.call(pos) if cb
      end

      def render
        div(class: "flex flex-col h-full") do
          div(class: s.bar) do
            div(class: s.tabs) do
              self.class.sorted.map do |p|
                div(class: s.tab(p.slug == state.active),
                    onclick: -> { patch(active: p.slug) }) do
                  p.title
                end
              end
            end
            div(class: "ml-auto flex items-center") do
              button(class: s.dockbtn, onclick: -> { dock(:bottom) }) do
                "⊥"
              end
              button(class: s.dockbtn, onclick: -> { dock(:right) }) do
                "⊣"
              end
            end
          end
          div(class: s.body) do
            active = self.class.sorted.find { |p| p.slug == state.active }
            component(active) if active
          end
        end
      end
    end
  end
end
