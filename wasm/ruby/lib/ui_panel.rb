# Harucom::UI::Panel: the base every feature panel inherits. A panel declares its
# tab title, slug, and order with the class DSL, then implements render (and,
# usually, component_mounted to subscribe to the engine). Subclasses self-register
# with Panels via inherited, so adding a feature is adding one *_panel.rb file.

module Harucom
  module UI
    class Panel < Component
      class << self
        def title(t = nil)
          t ? (@title = t) : @title
        end

        def slug(s = nil)
          s ? (@slug = s) : @slug
        end

        def order(n = nil)
          n ? (@order = n) : @order
        end

        def inherited(sub)
          super
          Panels.register(sub)
        end
      end
    end
  end
end
