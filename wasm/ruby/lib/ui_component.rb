# Harucom::UI::Component: the project base for every UI component. It gives each
# component the Engine as its one device window and removes any engine
# subscriptions automatically when the component unmounts (a tab switch or dock
# change tears panels down), so handlers never patch a dead component.

module Harucom
  module UI
    class Component < Funicular::Component
      def engine
        Harucom.engine
      end

      # Subscribe to an engine event and remember the token so component_unmounted
      # can off it. Call this from component_mounted.
      def on_engine(event, &block)
        @engine_subs ||= []
        token = engine.on(event, &block)
        @engine_subs << token
        token
      end

      def component_unmounted
        return unless @engine_subs
        i = 0
        while i < @engine_subs.length
          engine.off(@engine_subs[i])
          i += 1
        end
        @engine_subs = []
      end
    end
  end
end
