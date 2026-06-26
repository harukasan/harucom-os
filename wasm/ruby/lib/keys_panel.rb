# KeysPanel: the last key / HID / held readout (the former #kbddbg).
class KeysPanel < Harucom::UI::Panel
  title "Keys"
  slug "keys"
  order 20

  styles do
    pane "text-tab-inactive font-mono text-xs h-full overflow-auto p-2"
  end

  def initialize_state
    { info: Harucom.engine.key_info }
  end

  def component_mounted
    on_engine(:keys) { |info| patch(info: info) }
  end

  def render
    div(id: "keys", class: s.pane) do
      info = state.info
      (info && info.length > 0) ? info : "(no key)"
    end
  end
end
