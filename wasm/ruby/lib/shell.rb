# Entry point for the funicular browser UI (wasm only). The Engine writes the
# /_web/lib sources into MEMFS and loads this file (harucom_run_ruby), then calls
# Harucom::UI.boot with the panel list discovered at stage time. funicular itself
# is a gem in libmruby, so it needs no require. The OS sees /_web in `ls /`; that
# is accepted (see the wasm-funicular plan).
#
# Engine <-> UI bridge: the Engine exposes window.__harucomBridge. Engine -> UI is
# poll-based (stdout fires mid-mrb_run_step, so a synchronous JS -> Ruby callback
# would re-enter the VM); the ui_poll task drains it each scheduler pass via
# Harucom.engine.poll. UI -> Engine commands are direct JS calls.
require "engine"
require "ui_component"
require "ui_panels"
require "ui_panel"
require "ui_screen"
require "app"

module Harucom
  module UI
    # Require the panel files (each self-registers with Panels), mount the App,
    # and start the task that drains the Engine bridge each scheduler pass.
    def self.boot(panel_names)
      i = 0
      while i < panel_names.length
        require panel_names[i]
        i += 1
      end
      Funicular.start(App, container: "app")
      Task.new(name: "ui_poll") do
        loop do
          Harucom.engine.poll
          Task.pass
        end
      end
    end
  end
end
