# dmx_demo: DMX fader console for the picoruby-dmx engine.
#
# Run from IRB:  run app/dmx_demo.rb
#
# A bank of faders drives arbitrary DMX channels through the background
# engine. Fixture definitions in the Open Fixture Library JSON format
# (a tolerant subset) can be loaded from /data/dmx/fixtures/*.json to
# name the faders and label capability bands. The layout adapts to the
# text grid at startup, so the zoomed 320x240 console works as well.
#
# Keys:
#   Left/Right       select fader
#   Up/Down          value +-3, with Shift +-1
#   PageUp/PageDown  value +-16
#   Home / End       maximum / minimum
#   a                base address, repatches faders to address+index
#   c                channel of the selected fader
#   r                range of the selected fader ("min max")
#   Ctrl-O           load a fixture file
#   b                blackout
#   q / Esc / Ctrl-C blackout, stop the engine, return to IRB

DMX_DEMO_FIXTURE_DIR = "/data/dmx/fixtures"

# Read an OFL fixture JSON. Only a subset is used (availableChannels
# with fineChannelAliases, defaultValue and capability dmxRanges, plus
# modes); unknown keys are ignored, so files downloaded from
# open-fixture-library.org work unless they rely on matrix template
# channels. Returns {name:, modes: [{label:, channels: []}]} or nil.
def dmx_demo_read_fixture(path)
  return nil unless File.exist?(path)
  text = File.open(path, "r") { |f| f.read }
  return nil unless text
  begin
    data = JSON.parse(text)
  rescue
    return nil
  end
  return nil unless data.is_a?(Hash)
  available = data["availableChannels"]
  modes = data["modes"]
  return nil unless available.is_a?(Hash) && modes.is_a?(Array)

  # Fine channel aliases appear in mode lists but are defined on their
  # coarse parent; they carry no capabilities of their own.
  fine = {}
  available.each do |key, defn|
    next unless defn.is_a?(Hash)
    aliases = defn["fineChannelAliases"]
    next unless aliases.is_a?(Array)
    i = 0
    while i < aliases.length
      fine[aliases[i]] = key
      i += 1
    end
  end

  parsed = []
  mi = 0
  while mi < modes.length
    mode = modes[mi]
    mi += 1
    next unless mode.is_a?(Hash) && mode["channels"].is_a?(Array)
    list = mode["channels"]
    channels = []
    ci = 0
    while ci < list.length
      key = list[ci]
      ci += 1
      defn = key ? available[key] : nil
      defn = nil unless defn.is_a?(Hash)
      defn = nil if key && fine[key]
      channels << {
        name: key,
        default: dmx_demo_default_value(defn),
        caps: dmx_demo_capabilities(defn),
      }
    end
    next if channels.empty?
    label = mode["shortName"] || mode["name"] || "mode #{parsed.length + 1}"
    parsed << { label: label, channels: channels }
  end
  return nil if parsed.empty?
  name = data["name"]
  name = path.split("/").last unless name.is_a?(String)
  { name: name, modes: parsed }
end

def dmx_demo_default_value(defn)
  return 0 unless defn.is_a?(Hash)
  value = defn["defaultValue"]
  return 0 unless value.is_a?(Integer)
  return 0 if value < 0
  return 255 if 255 < value
  value
end

# Normalize capability/capabilities into [[min, max, label], ...].
def dmx_demo_capabilities(defn)
  return [] unless defn.is_a?(Hash)
  list = defn["capabilities"]
  list = [defn["capability"]] unless list.is_a?(Array)
  caps = []
  i = 0
  while i < list.length
    cap = list[i]
    i += 1
    next unless cap.is_a?(Hash)
    range = cap["dmxRange"]
    if range.is_a?(Array) && range[0].is_a?(Integer) && range[1].is_a?(Integer)
      caps << [range[0], range[1], dmx_demo_capability_label(cap)]
    else
      caps << [0, 255, dmx_demo_capability_label(cap)]
    end
  end
  caps
end

def dmx_demo_capability_label(cap)
  comment = cap["comment"]
  return comment if comment.is_a?(String) && !comment.empty?
  effect = cap["shutterEffect"]
  if effect.is_a?(String)
    if cap["speedStart"].is_a?(String) && cap["speedEnd"].is_a?(String)
      return "#{effect} #{cap["speedStart"]}..#{cap["speedEnd"]}"
    end
    return effect
  end
  type = cap["type"]
  type.is_a?(String) ? type : ""
end

def dmx_demo_fixture_paths(dir)
  paths = []
  return paths unless Dir.exist?(dir)
  Dir.open(dir) do |d|
    while entry = d.read
      next if entry == "." || entry == ".."
      paths << "#{dir}/#{entry}" if entry.end_with?(".json")
    end
  end
  paths.sort
end

def dmx_demo
  keyboard = $keyboard

  attr_text = 0xF0
  attr_bar  = 0x0F

  cols = DVI::Text.respond_to?(:cols) ? DVI::Text.cols : DVI::Text::COLS
  rows = DVI::Text.respond_to?(:rows) ? DVI::Text.rows : DVI::Text::ROWS

  fader_width = cols >= 100 ? 8 : 4
  visible = (cols - 2) / fader_width
  bar_height = rows - 8
  bar_height = 3 if bar_height < 3
  name_row = rows - 6
  channel_row = rows - 5
  value_row = rows - 4
  detail_row = rows - 3
  status_row = rows - 2
  command_row = rows - 1

  bar_chars = fader_width >= 8 ? 4 : 2
  pad_left = (fader_width - bar_chars) / 2
  pad_right = fader_width - bar_chars - pad_left
  bar_filled = (" " * pad_left) + ("#" * bar_chars) + (" " * pad_right)
  bar_empty = (" " * pad_left) + ("." * bar_chars) + (" " * pad_right)

  DVI.set_mode(DVI::TEXT_MODE)
  dma_channel = DMX.init  # board default wiring (Grove port)
  DMX.start               # clears the universe, first frames are dark
  DMX.deadman_ms = 500

  address = 1
  fixture_title = nil
  faders = []
  i = 0
  while i < 12
    faders << { ch: address + i, name: nil, value: 0, min: 0, max: 255, caps: [] }
    i += 1
  end
  selected = 0
  window = 0

  # Measured refresh rate over roughly 1 s windows, like the engine
  # sees it: a drop below 40 means the collision guard skipped frames.
  rate_fc = DMX.frame_count
  rate_ms = Machine.board_millis
  rate_text = "--.-"

  fader_x = lambda do |i2|
    1 + (i2 - window) * fader_width
  end

  cap_label = lambda do |fader|
    caps = fader[:caps]
    i2 = 0
    while i2 < caps.length
      cap = caps[i2]
      i2 += 1
      return cap[2] if cap[0] <= fader[:value] && fader[:value] <= cap[1]
    end
    ""
  end

  draw_title = lambda do
    title = " DMX demo  addr #{address}"
    title += "  #{fixture_title}" if fixture_title
    title += "  DMA ch#{dma_channel}"
    DVI::Text.put_string(0, 0, title.ljust(cols)[0, cols], attr_bar)
  end

  draw_fader = lambda do |i2|
    if i2 >= window && i2 < window + visible && i2 < faders.length
      fader = faders[i2]
      x = fader_x.call(i2)
      attr = i2 == selected ? attr_bar : attr_text
      span = fader[:max] - fader[:min]
      span = 1 if span < 1
      fill = (fader[:value] - fader[:min]) * bar_height / span
      fill = 0 if fill < 0
      fill = bar_height if bar_height < fill
      r = 0
      while r < bar_height
        cell = (bar_height - r) <= fill ? bar_filled : bar_empty
        DVI::Text.put_string(x, 1 + r, cell, attr)
        r += 1
      end
      name = fader[:name] ? fader[:name][0, fader_width - 1] : ""
      DVI::Text.put_string(x, name_row, name.ljust(fader_width), attr)
      DVI::Text.put_string(x, channel_row, fader[:ch].to_s.rjust(fader_width - 1) + " ", attr)
      DVI::Text.put_string(x, value_row, fader[:value].to_s.rjust(fader_width - 1) + " ", attr)
    end
  end

  draw_detail = lambda do
    fader = faders[selected]
    name = fader[:name] || "-"
    text = " ch #{fader[:ch]}  #{name}  #{fader[:min]}..#{fader[:max]} = #{fader[:value]}"
    label = cap_label.call(fader)
    text += "  [#{label}]" unless label.empty?
    DVI::Text.put_string(0, detail_row, text.ljust(cols)[0, cols], attr_text)
  end

  draw_status = lambda do
    now = Machine.board_millis
    if now - rate_ms >= 1000
      fc = DMX.frame_count
      hz10 = (fc - rate_fc) * 10000 / (now - rate_ms)
      rate_text = "#{hz10 / 10}.#{hz10 % 10}"
      rate_fc = fc
      rate_ms = now
    end
    text = " frames #{DMX.frame_count}  rate #{rate_text} Hz"
    DVI::Text.put_string(0, status_row, text.ljust(cols)[0, cols], attr_text)
  end

  draw_help = lambda do
    help = " a addr  c ch  r range  ^O fixture  b blkout  q quit"
    DVI::Text.put_string(0, command_row, help.ljust(cols)[0, cols], attr_bar)
  end

  redraw = lambda do
    DVI::Text.clear(attr_text)
    draw_title.call
    i2 = window
    while i2 < window + visible && i2 < faders.length
      draw_fader.call(i2)
      i2 += 1
    end
    draw_detail.call
    draw_status.call
    draw_help.call
  end

  # Push a fader value to the engine and update its column.
  set_value = lambda do |fader, value|
    value = fader[:min] if value < fader[:min]
    value = fader[:max] if fader[:max] < value
    if value != fader[:value]
      fader[:value] = value
      DMX.set(fader[:ch], value)
    end
  end

  # Replace the fader bank, zeroing channels that are left behind so no
  # light is stranded, then push the new values.
  apply_faders = lambda do |new_faders|
    leaving = {}
    i2 = 0
    while i2 < faders.length
      leaving[faders[i2][:ch]] = true
      i2 += 1
    end
    i2 = 0
    while i2 < new_faders.length
      leaving.delete(new_faders[i2][:ch])
      i2 += 1
    end
    leaving.each { |ch, _| DMX.set(ch, 0) }
    faders = new_faders
    selected = faders.length <= selected ? faders.length - 1 : selected
    window = 0
    window = selected - visible + 1 if selected >= visible
    i2 = 0
    while i2 < faders.length
      DMX.set(faders[i2][:ch], faders[i2][:value])
      i2 += 1
    end
  end

  # Single line prompt on the command bar. Returns the input or nil.
  prompt = lambda do |label|
    buf = ""
    result = nil
    loop do
      text = " #{label}: #{buf}_"
      DVI::Text.put_string(0, command_row, text.ljust(cols)[0, cols], attr_bar)
      DVI::Text.commit
      k = keyboard.read_char
      if k
        if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C
          break
        elsif k == Keyboard::ENTER
          result = buf
          break
        elsif k == Keyboard::BSPACE
          buf = buf[0, buf.length - 1] if buf.length > 0
        elsif k.printable? && k.char && buf.length < 16
          buf += k.char
        end
      end
      DMX.keepalive
      sleep_ms 20
    end
    result
  end

  # Full screen numbered list. Returns the picked index or nil.
  pick = lambda do |title, items|
    DVI::Text.clear(attr_text)
    DVI::Text.put_string(0, 0, " #{title}".ljust(cols)[0, cols], attr_bar)
    count = items.length < 9 ? items.length : 9
    i2 = 0
    while i2 < count
      DVI::Text.put_string(2, 2 + i2, "#{i2 + 1}  #{items[i2]}"[0, cols - 2], attr_text)
      i2 += 1
    end
    DVI::Text.put_string(2, 2, "(no entries)", attr_text) if count == 0
    DVI::Text.put_string(0, command_row, " 1-#{count} select   Esc cancel".ljust(cols)[0, cols], attr_bar)
    DVI::Text.commit
    choice = nil
    loop do
      k = keyboard.read_char
      if k
        break if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C
        if k.char && "1" <= k.char && k.char <= "9"
          n = k.char.to_i
          if n <= count
            choice = n - 1
            break
          end
        end
      end
      DMX.keepalive
      sleep_ms 20
    end
    choice
  end

  load_fixture = lambda do
    paths = dmx_demo_fixture_paths(DMX_DEMO_FIXTURE_DIR)
    names = []
    i2 = 0
    while i2 < paths.length
      names << paths[i2].split("/").last
      i2 += 1
    end
    pi = pick.call("Load fixture (#{DMX_DEMO_FIXTURE_DIR})", names)
    if pi
      fixture = dmx_demo_read_fixture(paths[pi])
      if fixture.nil?
        fixture_title = "load failed: #{names[pi]}"
      else
        mode = fixture[:modes][0]
        if fixture[:modes].length > 1
          labels = []
          i2 = 0
          while i2 < fixture[:modes].length
            labels << fixture[:modes][i2][:label]
            i2 += 1
          end
          mi = pick.call("Mode of #{fixture[:name]}", labels)
          mode = mi ? fixture[:modes][mi] : nil
        end
        if mode
          new_faders = []
          i2 = 0
          while i2 < mode[:channels].length
            channel = mode[:channels][i2]
            new_faders << {
              ch: address + i2,
              name: channel[:name],
              value: channel[:default],
              min: 0, max: 255,
              caps: channel[:caps],
            }
            i2 += 1
          end
          fixture_title = "#{fixture[:name]} (#{mode[:label]})"
          apply_faders.call(new_faders)
        end
      end
    end
  end

  blackout = lambda do
    i2 = 0
    while i2 < faders.length
      faders[i2][:value] = 0
      i2 += 1
    end
    DMX.blackout
  end

  redraw.call
  DVI::Text.commit
  status_at = Machine.board_millis

  loop do
    dirty = false
    structural = false
    k = keyboard.read_char
    if k
      if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C ||
         (k.printable? && (k.char == "q" || k.char == "Q"))
        break
      elsif k.match?(:o, ctrl: true)
        load_fixture.call
        structural = true
      elsif k.match?(:left)
        if selected > 0
          selected -= 1
          if selected < window
            window = selected
            structural = true
          else
            draw_fader.call(selected)
            draw_fader.call(selected + 1)
            draw_detail.call
            dirty = true
          end
        end
      elsif k.match?(:right)
        if selected < faders.length - 1
          selected += 1
          if selected >= window + visible
            window = selected - visible + 1
            structural = true
          else
            draw_fader.call(selected)
            draw_fader.call(selected - 1)
            draw_detail.call
            dirty = true
          end
        end
      elsif k.match?(:up)
        set_value.call(faders[selected], faders[selected][:value] + (k.shift? ? 1 : 3))
        draw_fader.call(selected)
        draw_detail.call
        dirty = true
      elsif k.match?(:down)
        set_value.call(faders[selected], faders[selected][:value] - (k.shift? ? 1 : 3))
        draw_fader.call(selected)
        draw_detail.call
        dirty = true
      elsif k.match?(:pageup)
        set_value.call(faders[selected], faders[selected][:value] + 16)
        draw_fader.call(selected)
        draw_detail.call
        dirty = true
      elsif k.match?(:pagedown)
        set_value.call(faders[selected], faders[selected][:value] - 16)
        draw_fader.call(selected)
        draw_detail.call
        dirty = true
      elsif k.match?(:home)
        set_value.call(faders[selected], faders[selected][:max])
        draw_fader.call(selected)
        draw_detail.call
        dirty = true
      elsif k.match?(:end)
        set_value.call(faders[selected], faders[selected][:min])
        draw_fader.call(selected)
        draw_detail.call
        dirty = true
      elsif k.printable? && k.char == "a"
        input = prompt.call("address (1-#{513 - faders.length})")
        if input && input.to_i >= 1 && input.to_i <= 513 - faders.length
          address = input.to_i
          new_faders = []
          i2 = 0
          while i2 < faders.length
            fader = faders[i2]
            new_faders << {
              ch: address + i2,
              name: fader[:name], value: fader[:value],
              min: fader[:min], max: fader[:max], caps: fader[:caps],
            }
            i2 += 1
          end
          apply_faders.call(new_faders)
        end
        structural = true
      elsif k.printable? && k.char == "c"
        input = prompt.call("channel (1-512)")
        if input && input.to_i >= 1 && input.to_i <= 512
          fader = faders[selected]
          old = fader[:ch]
          fader[:ch] = input.to_i
          DMX.set(old, 0) unless dmx_demo_channel_used(faders, old)
          DMX.set(fader[:ch], fader[:value])
        end
        structural = true
      elsif k.printable? && k.char == "r"
        input = prompt.call("range (min max)")
        if input
          parts = input.split(" ")
          min = parts[0] ? parts[0].to_i : nil
          max = parts[1] ? parts[1].to_i : nil
          if min && max && min >= 0 && max <= 255 && min < max
            fader = faders[selected]
            fader[:min] = min
            fader[:max] = max
            set_value.call(fader, fader[:value])
          end
        end
        structural = true
      elsif k.printable? && (k.char == "b" || k.char == "B")
        blackout.call
        structural = true
      end
    end

    if structural
      redraw.call
      dirty = true
    elsif Machine.board_millis - status_at >= 250
      # Refresh the frame counter and rate a few times per second.
      draw_status.call
      status_at = Machine.board_millis
      dirty = true
    end

    DMX.keepalive
    if dirty
      DVI::Text.commit
    else
      sleep_ms 16
    end
  end

  # Go dark, let the zero frames reach the fixtures, then stop.
  blackout.call
  8.times do
    DMX.keepalive
    sleep_ms 25
  end
  DMX.stop
  DVI::Text.clear(attr_text)
  DVI::Text.commit
  puts "dmx_demo: done (engine stopped, rig blacked out)."
end

# True when another fader still drives the channel.
def dmx_demo_channel_used(faders, channel)
  i = 0
  while i < faders.length
    return true if faders[i][:ch] == channel
    i += 1
  end
  false
end

dmx_demo
