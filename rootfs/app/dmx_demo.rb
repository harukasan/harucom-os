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

require "dmx/fixture"

class DmxDemo
  FIXTURE_DIR = "/data/dmx/fixtures"
  TEXT_ATTR = 0xF0
  BAR_ATTR  = 0x0F

  def initialize
    @keyboard = $keyboard

    @cols = DVI::Text.cols
    @rows = DVI::Text.rows

    @fader_width = @cols >= 100 ? 8 : 4
    @visible = (@cols - 2) / @fader_width
    @bar_height = @rows - 8
    @bar_height = 3 if @bar_height < 3
    @name_row = @rows - 6
    @channel_row = @rows - 5
    @value_row = @rows - 4
    @detail_row = @rows - 3
    @status_row = @rows - 2
    @command_row = @rows - 1

    bar_chars = @fader_width >= 8 ? 4 : 2
    pad_left = (@fader_width - bar_chars) / 2
    pad_right = @fader_width - bar_chars - pad_left
    @bar_filled = (" " * pad_left) + ("#" * bar_chars) + (" " * pad_right)
    @bar_empty = (" " * pad_left) + ("." * bar_chars) + (" " * pad_right)

    @address = 1
    @fixture_title = nil
    @faders = []
    i = 0
    while i < 12
      @faders << { ch: @address + i, name: nil, value: 0, min: 0, max: 255, caps: [] }
      i += 1
    end
    @selected = 0
    @window = 0
  end

  def run
    DVI.set_mode(DVI::TEXT_MODE)
    @dma_channel = DMX.init  # board default wiring (Grove port)
    DMX.start                # clears the universe, first frames are dark
    DMX.deadman_ms = 500

    # Measured refresh rate over roughly 1 s windows, like the engine
    # sees it: a drop below 40 means the collision guard skipped frames.
    @rate_fc = DMX.frame_count
    @rate_ms = Machine.board_millis
    @rate_text = "--.-"

    redraw
    DVI::Text.commit
    status_at = Machine.board_millis

    loop do
      dirty = false
      structural = false
      k = @keyboard.read_char
      if k
        if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C ||
           (k.printable? && (k.char == "q" || k.char == "Q"))
          break
        elsif k.match?(:o, ctrl: true)
          load_fixture
          structural = true
        elsif k.match?(:left)
          if @selected > 0
            @selected -= 1
            if @selected < @window
              @window = @selected
              structural = true
            else
              draw_fader(@selected)
              draw_fader(@selected + 1)
              draw_detail
              dirty = true
            end
          end
        elsif k.match?(:right)
          if @selected < @faders.length - 1
            @selected += 1
            if @selected >= @window + @visible
              @window = @selected - @visible + 1
              structural = true
            else
              draw_fader(@selected)
              draw_fader(@selected - 1)
              draw_detail
              dirty = true
            end
          end
        elsif k.match?(:up)
          set_value(@faders[@selected], @faders[@selected][:value] + (k.shift? ? 1 : 3))
          draw_fader(@selected)
          draw_detail
          dirty = true
        elsif k.match?(:down)
          set_value(@faders[@selected], @faders[@selected][:value] - (k.shift? ? 1 : 3))
          draw_fader(@selected)
          draw_detail
          dirty = true
        elsif k.match?(:pageup)
          set_value(@faders[@selected], @faders[@selected][:value] + 16)
          draw_fader(@selected)
          draw_detail
          dirty = true
        elsif k.match?(:pagedown)
          set_value(@faders[@selected], @faders[@selected][:value] - 16)
          draw_fader(@selected)
          draw_detail
          dirty = true
        elsif k.match?(:home)
          set_value(@faders[@selected], @faders[@selected][:max])
          draw_fader(@selected)
          draw_detail
          dirty = true
        elsif k.match?(:end)
          set_value(@faders[@selected], @faders[@selected][:min])
          draw_fader(@selected)
          draw_detail
          dirty = true
        elsif k.printable? && k.char == "a"
          input = prompt("address (1-#{513 - @faders.length})")
          if input && input.to_i >= 1 && input.to_i <= 513 - @faders.length
            @address = input.to_i
            new_faders = []
            i = 0
            while i < @faders.length
              fader = @faders[i]
              new_faders << {
                ch: @address + i,
                name: fader[:name], value: fader[:value],
                min: fader[:min], max: fader[:max], caps: fader[:caps],
              }
              i += 1
            end
            apply_faders(new_faders)
          end
          structural = true
        elsif k.printable? && k.char == "c"
          input = prompt("channel (1-512)")
          if input && input.to_i >= 1 && input.to_i <= 512
            fader = @faders[@selected]
            old = fader[:ch]
            fader[:ch] = input.to_i
            DMX.set(old, 0) unless channel_used?(old)
            DMX.set(fader[:ch], fader[:value])
          end
          structural = true
        elsif k.printable? && k.char == "r"
          input = prompt("range (min max)")
          if input
            parts = input.split(" ")
            min = parts[0] ? parts[0].to_i : nil
            max = parts[1] ? parts[1].to_i : nil
            if min && max && min >= 0 && max <= 255 && min < max
              fader = @faders[@selected]
              fader[:min] = min
              fader[:max] = max
              set_value(fader, fader[:value])
            end
          end
          structural = true
        elsif k.printable? && (k.char == "b" || k.char == "B")
          blackout
          structural = true
        end
      end

      if structural
        redraw
        dirty = true
      elsif Machine.board_millis - status_at >= 250
        # Refresh the frame counter and rate a few times per second.
        draw_status
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
    blackout
    8.times do
      DMX.keepalive
      sleep_ms 25
    end
    DMX.stop
    DVI::Text.clear(TEXT_ATTR)
    DVI::Text.commit
    puts "dmx_demo: done (engine stopped, rig blacked out)."
  end

  private

  def fader_x(index)
    1 + (index - @window) * @fader_width
  end

  def cap_label(fader)
    caps = fader[:caps]
    i = 0
    while i < caps.length
      cap = caps[i]
      i += 1
      return cap[2] if cap[0] <= fader[:value] && fader[:value] <= cap[1]
    end
    ""
  end

  def draw_title
    title = " DMX demo  addr #{@address}"
    title += "  #{@fixture_title}" if @fixture_title
    title += "  DMA ch#{@dma_channel}"
    DVI::Text.put_string(0, 0, title.ljust(@cols)[0, @cols], BAR_ATTR)
  end

  def draw_fader(index)
    if index >= @window && index < @window + @visible && index < @faders.length
      fader = @faders[index]
      x = fader_x(index)
      attr = index == @selected ? BAR_ATTR : TEXT_ATTR
      span = fader[:max] - fader[:min]
      span = 1 if span < 1
      fill = (fader[:value] - fader[:min]) * @bar_height / span
      fill = 0 if fill < 0
      fill = @bar_height if @bar_height < fill
      r = 0
      while r < @bar_height
        cell = (@bar_height - r) <= fill ? @bar_filled : @bar_empty
        DVI::Text.put_string(x, 1 + r, cell, attr)
        r += 1
      end
      name = fader[:name] ? fader[:name][0, @fader_width - 1] : ""
      DVI::Text.put_string(x, @name_row, name.ljust(@fader_width), attr)
      DVI::Text.put_string(x, @channel_row, fader[:ch].to_s.rjust(@fader_width - 1) + " ", attr)
      DVI::Text.put_string(x, @value_row, fader[:value].to_s.rjust(@fader_width - 1) + " ", attr)
    end
  end

  def draw_detail
    fader = @faders[@selected]
    name = fader[:name] || "-"
    text = " ch #{fader[:ch]}  #{name}  #{fader[:min]}..#{fader[:max]} = #{fader[:value]}"
    label = cap_label(fader)
    text += "  [#{label}]" unless label.empty?
    DVI::Text.put_string(0, @detail_row, text.ljust(@cols)[0, @cols], TEXT_ATTR)
  end

  def draw_status
    now = Machine.board_millis
    if now - @rate_ms >= 1000
      fc = DMX.frame_count
      hz10 = (fc - @rate_fc) * 10000 / (now - @rate_ms)
      @rate_text = "#{hz10 / 10}.#{hz10 % 10}"
      @rate_fc = fc
      @rate_ms = now
    end
    text = " frames #{DMX.frame_count}  rate #{@rate_text} Hz"
    DVI::Text.put_string(0, @status_row, text.ljust(@cols)[0, @cols], TEXT_ATTR)
  end

  def draw_help
    help = " a addr  c ch  r range  ^O fixture  b blkout  q quit"
    DVI::Text.put_string(0, @command_row, help.ljust(@cols)[0, @cols], BAR_ATTR)
  end

  def redraw
    DVI::Text.clear(TEXT_ATTR)
    draw_title
    i = @window
    while i < @window + @visible && i < @faders.length
      draw_fader(i)
      i += 1
    end
    draw_detail
    draw_status
    draw_help
  end

  # Push a fader value to the engine and update its column.
  def set_value(fader, value)
    value = fader[:min] if value < fader[:min]
    value = fader[:max] if fader[:max] < value
    if value != fader[:value]
      fader[:value] = value
      DMX.set(fader[:ch], value)
    end
  end

  # Replace the fader bank, zeroing channels that are left behind so no
  # light is stranded, then push the new values.
  def apply_faders(new_faders)
    leaving = {}
    i = 0
    while i < @faders.length
      leaving[@faders[i][:ch]] = true
      i += 1
    end
    i = 0
    while i < new_faders.length
      leaving.delete(new_faders[i][:ch])
      i += 1
    end
    leaving.each { |ch, _| DMX.set(ch, 0) }
    @faders = new_faders
    @selected = @faders.length <= @selected ? @faders.length - 1 : @selected
    @window = 0
    @window = @selected - @visible + 1 if @selected >= @visible
    i = 0
    while i < @faders.length
      DMX.set(@faders[i][:ch], @faders[i][:value])
      i += 1
    end
  end

  # True when another fader still drives the channel.
  def channel_used?(channel)
    i = 0
    while i < @faders.length
      return true if @faders[i][:ch] == channel
      i += 1
    end
    false
  end

  # Single line prompt on the command bar. Returns the input or nil.
  def prompt(label)
    buf = ""
    result = nil
    loop do
      text = " #{label}: #{buf}_"
      DVI::Text.put_string(0, @command_row, text.ljust(@cols)[0, @cols], BAR_ATTR)
      DVI::Text.commit
      k = @keyboard.read_char
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
  def pick(title, items)
    DVI::Text.clear(TEXT_ATTR)
    DVI::Text.put_string(0, 0, " #{title}".ljust(@cols)[0, @cols], BAR_ATTR)
    count = items.length < 9 ? items.length : 9
    i = 0
    while i < count
      DVI::Text.put_string(2, 2 + i, "#{i + 1}  #{items[i]}"[0, @cols - 2], TEXT_ATTR)
      i += 1
    end
    DVI::Text.put_string(2, 2, "(no entries)", TEXT_ATTR) if count == 0
    DVI::Text.put_string(0, @command_row, " 1-#{count} select   Esc cancel".ljust(@cols)[0, @cols], BAR_ATTR)
    DVI::Text.commit
    choice = nil
    loop do
      k = @keyboard.read_char
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

  def load_fixture
    paths = DMX::Fixture.list(FIXTURE_DIR)
    names = []
    i = 0
    while i < paths.length
      names << paths[i].split("/").last
      i += 1
    end
    pi = pick("Load fixture (#{FIXTURE_DIR})", names)
    if pi
      fixture = DMX::Fixture.read(paths[pi])
      if fixture.nil?
        @fixture_title = "load failed: #{names[pi]}"
      else
        mode = fixture[:modes][0]
        if fixture[:modes].length > 1
          labels = []
          i = 0
          while i < fixture[:modes].length
            labels << fixture[:modes][i][:label]
            i += 1
          end
          mi = pick("Mode of #{fixture[:name]}", labels)
          mode = mi ? fixture[:modes][mi] : nil
        end
        if mode
          new_faders = []
          i = 0
          while i < mode[:channels].length
            channel = mode[:channels][i]
            new_faders << {
              ch: @address + i,
              name: channel[:name],
              value: channel[:default],
              min: 0, max: 255,
              caps: channel[:caps],
            }
            i += 1
          end
          @fixture_title = "#{fixture[:name]} (#{mode[:label]})"
          apply_faders(new_faders)
        end
      end
    end
  end

  def blackout
    i = 0
    while i < @faders.length
      @faders[i][:value] = 0
      i += 1
    end
    DMX.blackout
  end
end

DmxDemo.new.run
