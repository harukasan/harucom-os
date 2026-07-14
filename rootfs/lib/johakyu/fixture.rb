# Johakyu fixture model: Personality (channel map) + Patch (base address
# assignment) + Group (broadcast, optional spread).
#
# The DMX universe lives in the C engine (picoruby-dmx). This layer only
# resolves attribute names to absolute channels and quantizes values. It
# never caches channel values in Ruby; DMX.get reads the engine directly.
#
# Personalities come from Open Fixture Library JSON definitions under
# /data/dmx/fixtures (the DMX::Fixture loader), converted by
# Personality.from_ofl. The patch is assigned from the live script
# (fixture/group statements, see live.rb); there is no built-in rig.
#
# Usage:
#   require "johakyu/fixture"
#   personality = Johakyu.personality("shehds_80w_led_spot_light", "13ch")
#   patch = Johakyu::Patch.new
#   patch.add(:s1, personality, base: 1)
#   patch.group(:all, :s1)
#   Johakyu.patch = patch
#   DMX.active_slots = patch.max_channel     # shorten frames to used range
#   Johakyu.dmx(:s1).pan(0.5).tilt(0.2)      # normalized 0.0-1.0, chainable
#   Johakyu.dmx(:all).dimmer(1.0)            # group broadcast
#   Johakyu.dmx(:all).spread(0.5).pan(0.25)  # fan values across members
#   Johakyu.dmx(:s1).color(:red)             # named wheel positions
#   Johakyu.dmx(:s1).raw(:pan, 200)          # raw 0-255 escape hatch

require "dmx/fixture"

module Johakyu
  # Fixture personality attributes addressable from patterns. Also the
  # single source of the attribute sugar: AttributeMethods,
  # ControlBuilder, Pattern, TrackProxy, LiveDmxBuilder, and the
  # top-level live DSL generate one method per entry.
  LIGHT_CONTROLS = [:pan, :tilt, :dimmer, :strobe, :color, :gobo, :focus, :prism, :speed]

  # Attribute sugar shared by Fixture, Group and Spread. Each method
  # forwards to set(attribute, value) and returns self for chaining.
  module AttributeMethods
    LIGHT_CONTROLS.each do |attribute|
      define_method(attribute) { |value| set(attribute, value) }
    end
  end

  # DMX chart of one fixture model: attribute name to channel offset
  # (1-based), name tables for wheel attributes, and value ranges for
  # attributes whose active band does not start at 0 (e.g. strobe).
  # Offsets ending in _fine mark the low byte of a 16 bit pair; set()
  # detects them automatically.
  class Personality
    attr_reader :name, :channels, :map, :tables, :ranges

    def initialize(name:, channels:, map:, tables: {}, ranges: {})
      @name = name
      @channels = channels
      @map = map
      @tables = tables
      @ranges = ranges
      @fine = {}
      map.each do |key, _offset|
        s = key.to_s
        if s.length > 5 && s[s.length - 5, 5] == "_fine"
          @fine[s[0, s.length - 5].to_sym] = key
        end
      end
    end

    def offset(attribute)
      @map[attribute]
    end

    # Fine (low byte) attribute paired with a coarse attribute, or nil.
    def fine_attribute(attribute)
      @fine[attribute]
    end

    def table(attribute)
      @tables[attribute]
    end

    def range(attribute)
      @ranges[attribute]
    end

    # Build a Personality from a parsed OFL fixture (DMX::Fixture.read)
    # and a mode label (first mode when nil). Channel order gives the
    # offsets; attributes are classified by OFL capability type, with
    # the slugged channel name as the fallback. Wheel, prism, and
    # effect channels get name tables from their capability labels
    # (band midpoint values); a strobe channel gets its active range
    # from the widest capability band.
    def self.from_ofl(fixture, mode_label = nil)
      mode = nil
      modes = fixture[:modes]
      if mode_label
        i = 0
        while i < modes.length
          mode = modes[i] if modes[i][:label] == mode_label
          i += 1
        end
        unless mode
          raise ArgumentError, "unknown mode #{mode_label} for #{fixture[:name]}"
        end
      else
        mode = modes[0]
      end

      map = {}
      tables = {}
      ranges = {}
      by_name = {}
      channels = mode[:channels]
      i = 0
      while i < channels.length
        entry = channels[i]
        offset = i + 1
        i += 1
        name = entry[:name]
        next unless name
        attribute = ofl_attribute(name, entry[:caps], by_name)
        next unless attribute
        next if map[attribute]
        map[attribute] = offset
        by_name[name] = attribute
        table = ofl_table(entry[:caps])
        tables[attribute] = table if table
        range = ofl_range(entry[:caps])
        ranges[attribute] = range if range
      end

      Personality.new(
        name: "#{fixture[:name]} #{mode[:label]}",
        channels: channels.length,
        map: map,
        tables: tables,
        ranges: ranges,
      )
    end

    # Capability types that make a channel a named-position channel
    # (wheel slots, prism modes, effect and maintenance bands).
    TABLE_TYPES = {
      "WheelSlot" => true, "WheelShake" => true, "WheelRotation" => true,
      "Prism" => true, "PrismRotation" => true,
      "Effect" => true, "Maintenance" => true,
    }

    # Attribute symbol for one OFL channel. "<name> fine" channels pair
    # with their coarse parent seen earlier in the mode.
    def self.ofl_attribute(name, caps, by_name)
      if name.length > 5 && name[name.length - 5, 5] == " fine"
        parent = by_name[name[0, name.length - 5]]
        return parent ? "#{parent}_fine".to_sym : nil
      end
      types = {}
      i = 0
      while i < caps.length
        types[caps[i][3]] = true
        i += 1
      end
      return :pan if types["Pan"]
      return :tilt if types["Tilt"]
      return :speed if types["PanTiltSpeed"]
      return :dimmer if types["Intensity"]
      return :strobe if types["ShutterStrobe"]
      return :focus if types["Focus"]
      return :zoom if types["Zoom"]
      return :prism if types["Prism"] || types["PrismRotation"]
      if types["WheelSlot"] || types["WheelShake"] || types["WheelRotation"]
        lower = ofl_slug(name)
        return :color if lower && lower.include?("color")
        return :gobo if lower && lower.include?("gobo")
      end
      slug = ofl_slug(name)
      slug ? slug.to_sym : nil
    end

    # Name table from labeled capability bands: slugged label to the
    # band midpoint. Labels that fell back to the bare type are not
    # names and are skipped.
    def self.ofl_table(caps)
      wants = false
      i = 0
      while i < caps.length
        wants = true if TABLE_TYPES[caps[i][3]]
        i += 1
      end
      return nil unless wants
      table = {}
      i = 0
      while i < caps.length
        cap = caps[i]
        i += 1
        label = cap[2]
        next if label.nil? || label.length == 0 || label == cap[3]
        key = ofl_slug(label)
        next unless key
        table[key.to_sym] = (cap[0] + cap[1] + 1) / 2
      end
      table.empty? ? nil : table
    end

    # Active range for strobe-like channels whose effect band does not
    # start at zero: the widest capability band carries the effect.
    def self.ofl_range(caps)
      strobe = false
      i = 0
      while i < caps.length
        strobe = true if caps[i][3] == "ShutterStrobe"
        i += 1
      end
      return nil unless strobe
      best = nil
      i = 0
      while i < caps.length
        cap = caps[i]
        i += 1
        best = cap if best.nil? || cap[1] - cap[0] > best[1] - best[0]
      end
      [best[0], best[1]]
    end

    # Lowercase word joined with underscores: "light blue + white" to
    # "light_blue_white", "Gobo Wheel" to "gobo_wheel".
    def self.ofl_slug(text)
      result = ""
      i = 0
      while i < text.length
        ch = text[i]
        i += 1
        if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
          result += ch
        elsif ch >= "A" && ch <= "Z"
          result += ch.downcase
        elsif result.length > 0 && !result.end_with?("_")
          result += "_"
        end
      end
      result = result[0, result.length - 1].to_s while result.end_with?("_")
      result.length == 0 ? nil : result
    end
  end

  # One physical unit: a personality patched at a base address. The
  # fixture body must be set to the same address (menu Addr).
  class Fixture
    include AttributeMethods

    attr_reader :name, :personality, :base

    def initialize(name, personality, base)
      @name = name
      @personality = personality
      @base = base
    end

    # Absolute DMX channel of an attribute: base + offset - 1.
    def channel(attribute)
      offset = @personality.offset(attribute)
      unless offset
        raise ArgumentError, "unknown attribute #{attribute} for #{@personality.name}"
      end
      @base + offset - 1
    end

    def max_channel
      @base + @personality.channels - 1
    end

    # Write a raw 0-255 value to an attribute channel, bypassing
    # normalization and tables.
    def raw(attribute, value)
      ::DMX.set(channel(attribute), value)
      self
    end

    # Set an attribute. Symbol or String values look up the personality
    # name table (wheel positions). Numeric values are normalized
    # 0.0-1.0: quantized to 16 bit across coarse+fine when the
    # personality has a fine channel, otherwise to the attribute range
    # (value 0 writes raw 0 so ranged attributes like strobe turn off).
    def set(attribute, value)
      if value.is_a?(Symbol) || value.is_a?(String)
        table = @personality.table(attribute)
        unless table
          raise ArgumentError, "no name table for #{attribute} on #{@personality.name}"
        end
        entry = table[value.to_sym]
        unless entry
          raise ArgumentError, "unknown #{attribute} name #{value}"
        end
        ::DMX.set(channel(attribute), entry)
        return self
      end
      v = value.to_f
      v = 0.0 if v < 0.0
      v = 1.0 if v > 1.0
      fine = @personality.fine_attribute(attribute)
      if fine
        wide = (v * 65535.0 + 0.5).to_i
        coarse_channel = channel(attribute)
        fine_channel = channel(fine)
        if fine_channel == coarse_channel + 1
          ::DMX.set_range(coarse_channel, [wide >> 8, wide & 0xFF])
        else
          ::DMX.set(coarse_channel, wide >> 8)
          ::DMX.set(fine_channel, wide & 0xFF)
        end
      else
        range = @personality.range(attribute)
        if range && v > 0.0
          low = range[0]
          high = range[1]
          ::DMX.set(channel(attribute), low + ((high - low) * v + 0.5).to_i)
        else
          ::DMX.set(channel(attribute), (v * 255.0 + 0.5).to_i)
        end
      end
      self
    end
  end

  # A named list of fixtures. Attribute writes broadcast to every member.
  class Group
    include AttributeMethods

    attr_reader :name, :members

    def initialize(name, members)
      @name = name
      @members = members
    end

    def set(attribute, value)
      i = 0
      while i < @members.length
        @members[i].set(attribute, value)
        i += 1
      end
      self
    end

    def raw(attribute, value)
      i = 0
      while i < @members.length
        @members[i].raw(attribute, value)
        i += 1
      end
      self
    end

    # Fan values across members for chase effects: member i receives
    # value + amount * i / (n - 1). Named values broadcast unchanged.
    def spread(amount)
      Spread.new(@members, amount)
    end

    def max_channel
      max = 0
      i = 0
      while i < @members.length
        last = @members[i].max_channel
        max = last if last > max
        i += 1
      end
      max
    end
  end

  # Spread proxy returned by Group#spread. Values are offset per member
  # before quantization; Fixture#set clamps the result to 0.0-1.0.
  class Spread
    include AttributeMethods

    def initialize(members, amount)
      @members = members
      @amount = amount
    end

    def set(attribute, value)
      n = @members.length
      if n < 2 || value.is_a?(Symbol) || value.is_a?(String)
        i = 0
        while i < n
          @members[i].set(attribute, value)
          i += 1
        end
        return self
      end
      i = 0
      while i < n
        @members[i].set(attribute, value + @amount * i / (n - 1).to_f)
        i += 1
      end
      self
    end
  end

  # Base address assignment. Registers fixtures, rejects overlapping
  # channel ranges (address mistakes are the most common rig failure,
  # catch them at patch time), and defines groups.
  class Patch
    def initialize
      @fixtures = {}
      @groups = {}
      @order = []
    end

    def fixture_names
      @order
    end

    def add(name, personality, base:)
      if @fixtures[name] || @groups[name]
        raise ArgumentError, "duplicate name #{name}"
      end
      last = base + personality.channels - 1
      if base < 1 || last > 512
        raise ArgumentError, "#{name} channels #{base}-#{last} outside 1-512"
      end
      @fixtures.each do |other_name, other|
        other_last = other.base + other.personality.channels - 1
        if base <= other_last && other.base <= last
          raise ArgumentError,
            "#{name} (#{base}-#{last}) overlaps #{other_name} (#{other.base}-#{other_last})"
        end
      end
      fixture = Fixture.new(name, personality, base)
      @fixtures[name] = fixture
      @order << name
      fixture
    end

    # Define a group from fixture names, group names, or arrays of them.
    def group(name, *members)
      if @fixtures[name] || @groups[name]
        raise ArgumentError, "duplicate name #{name}"
      end
      list = []
      collect_members(members, list)
      @groups[name] = Group.new(name, list)
    end

    def [](name)
      @fixtures[name] || @groups[name]
    end

    def max_channel
      max = 0
      @fixtures.each do |_name, fixture|
        last = fixture.max_channel
        max = last if last > max
      end
      max
    end

    private

    def collect_members(members, list)
      members.each do |member|
        if member.is_a?(Array)
          collect_members(member, list)
        elsif @groups[member]
          @groups[member].members.each { |m| list << m }
        elsif @fixtures[member]
          list << @fixtures[member]
        else
          raise ArgumentError, "unknown member #{member}"
        end
      end
    end
  end

  # Where fixture statements resolve bare definition names.
  FIXTURE_DIR = "/data/dmx/fixtures"

  # Load a personality from an OFL fixture definition. A bare name
  # resolves under /data/dmx/fixtures with the .json suffix added; a
  # name containing a slash is used as a path. Personalities are
  # cached per definition and mode, so repeated patch statements do
  # not reread the file.
  def self.personality(file, mode = nil)
    @personalities ||= {}
    key = "#{file}|#{mode}"
    cached = @personalities[key]
    return cached if cached
    path = file.include?("/") ? file : "#{FIXTURE_DIR}/#{file}.json"
    fixture = ::DMX::Fixture.read(path)
    unless fixture
      raise ArgumentError, "fixture definition not found: #{path}"
    end
    @personalities[key] = Personality.from_ofl(fixture, mode)
  end

  # The running rig. Starts empty; the live script assigns it through
  # fixture/group statements (see live.rb).
  def self.patch
    @patch ||= Patch.new
  end

  def self.patch=(patch)
    @patch = patch
  end

  # Resolution context while a live recording builds a new rig:
  # pattern building resolves against the pending patch, so one eval
  # can patch fixtures and target them. Only the task recording the
  # script touches this; the dispatcher and views read Johakyu.patch.
  def self.build_patch=(patch)
    @build_patch = patch
  end

  # Resolve a fixture or group by name: Johakyu.dmx(:s1).pan(0.5).
  def self.dmx(name)
    target = (@build_patch || patch)[name]
    unless target
      raise ArgumentError, "unknown fixture or group #{name}"
    end
    target
  end
end
