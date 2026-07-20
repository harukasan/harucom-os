# KeyboardPanel: an on-screen keyboard (US 101-style main + navigation cluster).
# Each key sends a momentary HID press through the Engine (down on pointerdown,
# up on pointerup), driving the same report as the physical keyboard. Shift, Ctrl
# and Alt are latched overlay toggles: tapping one holds that modifier (caps-style)
# until tapped again, applied to every key until released. The left and right
# modifier keys share one latch (the OS does not distinguish them). HID usages
# come from the same table as hid.js; the OS maps usage + modifier to a character
# with its configured layout. Keys are uniform squares; Space spans the row.
class KeyboardPanel < Harucom::UI::Panel
  title "Keyboard"
  slug "keyboard"
  order 25

  SHIFT = 0x02 # HID LeftShift bit
  CTRL  = 0x01 # HID LeftControl bit
  ALT   = 0x04 # HID LeftAlt bit

  # Rows of [label, usage] regular keys, or [label, :shift|:ctrl|:alt] latch
  # toggles. An optional third element sets the key width; the default is a square.
  # Wide keys are sized in units of the square plus its gap (1.25u = w-[2.875rem],
  # 1.5u = w-[3.5rem], 1.75u = w-[4.125rem], 2u = w-[4.75rem], 2.25u = w-[5.375rem]),
  # so adjacent keys line up on the grid like a real keyboard.
  ROWS = [
    [["Esc", 0x29], ["F1", 0x3a], ["F2", 0x3b], ["F3", 0x3c], ["F4", 0x3d], ["F5", 0x3e],
     ["F6", 0x3f], ["F7", 0x40], ["F8", 0x41], ["F9", 0x42], ["F10", 0x43], ["F11", 0x44], ["F12", 0x45]],
    [["`", 0x35], ["1", 0x1e], ["2", 0x1f], ["3", 0x20], ["4", 0x21], ["5", 0x22], ["6", 0x23],
     ["7", 0x24], ["8", 0x25], ["9", 0x26], ["0", 0x27], ["-", 0x2d], ["=", 0x2e], ["Bksp", 0x2a, "w-[4.75rem]"]],
    [["Tab", 0x2b, "w-[2.875rem]"], ["Q", 0x14], ["W", 0x1a], ["E", 0x08], ["R", 0x15], ["T", 0x17], ["Y", 0x1c],
     ["U", 0x18], ["I", 0x0c], ["O", 0x12], ["P", 0x13], ["[", 0x2f], ["]", 0x30], ["\\", 0x31, "w-[3.5rem]"]],
    [["Caps", 0x39, "w-[3.5rem]"], ["A", 0x04], ["S", 0x16], ["D", 0x07], ["F", 0x09], ["G", 0x0a], ["H", 0x0b],
     ["J", 0x0d], ["K", 0x0e], ["L", 0x0f], [";", 0x33], ["'", 0x34], ["Enter", 0x28, "w-[5.375rem]"]],
    [["Shift", :shift, "w-[4.125rem]"], ["Z", 0x1d], ["X", 0x1b], ["C", 0x06], ["V", 0x19], ["B", 0x05], ["N", 0x11],
     ["M", 0x10], [",", 0x36], [".", 0x37], ["/", 0x38], ["Shift", :shift, "w-[4.125rem]"]],
    [["Ctrl", :ctrl, "w-[2.875rem]"], ["Alt", :alt, "w-[2.875rem]"], ["Space", 0x2c, "flex-1"],
     ["Alt", :alt, "w-[2.875rem]"], ["Ctrl", :ctrl, "w-[2.875rem]"]],
    [["Ins", 0x49], ["Home", 0x4a], ["PgUp", 0x4b], ["Del", 0x4c], ["End", 0x4d], ["PgDn", 0x4e],
     ["←", 0x50], ["↑", 0x52], ["↓", 0x51], ["→", 0x4f]],
  ]

  styles do
    wrap "p-2 select-none overflow-x-auto"
    row "flex gap-1 mb-1 whitespace-nowrap"
    key "h-9 rounded bg-pad text-fg text-xs flex items-center justify-center touch-none border border-border hover:bg-border-hover active:bg-pad-on active:text-[#16161e]"
    toggle base: "h-9 rounded text-xs flex items-center justify-center touch-none border border-border cursor-pointer bg-pad text-fg hover:bg-border-hover",
           active: "bg-pad-on text-[#16161e]"
  end

  def initialize_state
    { shift: false, ctrl: false, alt: false }
  end

  def key_press(usage)
    engine.key_down(usage)
  end

  def key_release(usage)
    engine.key_up(usage)
  end

  # Latch a modifier, then push the combined overlay so it applies to later keys.
  def toggle(which)
    case which
    when :shift then patch(shift: !state.shift)
    when :ctrl  then patch(ctrl: !state.ctrl)
    when :alt   then patch(alt: !state.alt)
    end
    mask = 0
    mask |= SHIFT if state.shift
    mask |= CTRL if state.ctrl
    mask |= ALT if state.alt
    engine.set_key_modifier(mask)
  end

  def key_button(label, usage, width)
    button(class: s.key | width, "data-usage": usage.to_s) do
      label
    end
  end

  def toggle_button(label, which, width)
    button(class: s.toggle(state[which]) | width, "data-mod": which.to_s) do
      label
    end
  end

  def render_key(entry)
    width = entry[2] || "w-9" # default to a square; wide keys (Space) override
    entry[1].is_a?(Symbol) ? toggle_button(entry[0], entry[1], width) : key_button(entry[0], entry[1], width)
  end

  # Read the HID usage a pointer event landed on from the target's data-usage.
  # getAttribute returns nil for the container and for toggle keys (no usage);
  # rescue guards a target that is not an element.
  def usage_at(event)
    val = event.target.getAttribute("data-usage")
    val && !val.empty? ? val.to_i : nil
  rescue StandardError
    nil
  end

  def press(event)
    usage = usage_at(event)
    return unless usage
    @pressed = usage
    key_press(usage)
  end

  # Release whatever key is held, regardless of where the pointer is now, so a
  # press that ends off its key still lifts (release-on-pointerup, delegated).
  def release(_event)
    return unless @pressed
    key_release(@pressed)
    @pressed = nil
  end

  def click(event)
    which = event.target.getAttribute("data-mod")
    toggle(which.to_sym) if which && !which.empty?
  rescue StandardError
    nil
  end

  # Event delegation: bind one set of listeners on the container instead of
  # three per key. Every addEventListener spawns a VM task, and a full re-render
  # rebinds every listener, so a per-key keyboard (~200 listeners) overwhelms the
  # scheduler on the first re-render. Delegating keeps it at a handful.
  def render
    div(id: "keyboard", class: s.wrap,
        onpointerdown: ->(e) { press(e) },
        onpointerup: ->(e) { release(e) },
        onpointerleave: ->(e) { release(e) },
        onclick: ->(e) { click(e) }) do
      i = 0
      while i < ROWS.length
        row = ROWS[i]
        div(class: s.row) do
          j = 0
          while j < row.length
            render_key(row[j])
            j += 1
          end
        end
        i += 1
      end
    end
  end
end
