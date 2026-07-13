# Johakyu fixture model: Personality (channel map) + Patch (base address
# assignment) + Group (broadcast, optional spread).
#
# The DMX universe lives in the C engine (picoruby-dmx). This layer only
# resolves attribute names to absolute channels and quantizes values. It
# never caches channel values in Ruby; DMX.get reads the engine directly.
#
# Usage:
#   require "johakyu/fixture"
#   patch = Johakyu.patch                    # default rig, see below
#   DMX.active_slots = patch.max_channel     # shorten frames to used range
#   Johakyu.dmx(:s1).pan(0.5).tilt(0.2)      # normalized 0.0-1.0, chainable
#   Johakyu.dmx(:all).dimmer(1.0)            # group broadcast
#   Johakyu.dmx(:all).spread(0.5).pan(0.25)  # fan values across members
#   Johakyu.dmx(:s1).color(:red)             # named wheel positions
#   Johakyu.dmx(:s1).raw(:pan, 200)          # raw 0-255 escape hatch
module Johakyu
  # Attribute sugar shared by Fixture, Group and Spread. Each method
  # forwards to set(attribute, value) and returns self for chaining.
  module AttributeMethods
    def pan(value)
      set(:pan, value)
    end

    def tilt(value)
      set(:tilt, value)
    end

    def dimmer(value)
      set(:dimmer, value)
    end

    def strobe(value)
      set(:strobe, value)
    end

    def color(value)
      set(:color, value)
    end

    def gobo(value)
      set(:gobo, value)
    end

    def focus(value)
      set(:focus, value)
    end

    def prism(value)
      set(:prism, value)
    end

    def speed(value)
      set(:speed, value)
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

  # SHEHDS LED Spot 80W (3 face prism) wheel tables, from the vendor
  # manual. Values sit mid band to stay clear of range boundaries.
  SHEHDS_SPOT_80W_COLORS = {
    white: 4, red: 12, green: 20, blue: 28, yellow: 36, pink: 44,
    light_green: 52, light_blue: 60,
    light_blue_white: 68, light_blue_light_green: 76,
    light_green_pink: 84, pink_yellow: 92, yellow_blue: 100,
    blue_green: 108, green_red: 116, red_white: 124,
    rotate: 192,
  }

  SHEHDS_SPOT_80W_GOBOS = {
    open: 4,
    gobo1: 13, gobo2: 21, gobo3: 30, gobo4: 38,
    gobo5: 47, gobo6: 55, gobo7: 64,
    gobo7_shake: 72, gobo6_shake: 81, gobo5_shake: 89, gobo4_shake: 98,
    gobo3_shake: 106, gobo2_shake: 115, gobo1_shake: 123,
    rotate: 192,
  }

  SHEHDS_SPOT_80W_PRISMS = {
    off: 0,       # 0-15
    on: 72,       # 16-127 prism in, static
    rotate: 192,  # 128-255
  }

  # CH13 (13ch mode) / CH10 (10ch mode). The manual lists full auto as
  # 150-249 and sound as 200-249, which overlap; the chosen values keep
  # full_auto in the unambiguous 150-199 band.
  SHEHDS_SPOT_80W_FUNCTIONS = {
    none: 0,
    full_auto: 180,
    sound: 225,
    reset: 252,   # 250-255, resets the fixture
  }

  SHEHDS_SPOT_80W_TABLES = {
    color: SHEHDS_SPOT_80W_COLORS,
    gobo: SHEHDS_SPOT_80W_GOBOS,
    prism: SHEHDS_SPOT_80W_PRISMS,
    function: SHEHDS_SPOT_80W_FUNCTIONS,
  }

  # Strobe is steady on below 16 (bench verified); 16-251 sets the
  # strobe frequency. strobe(0) writes raw 0 for steady light.
  SHEHDS_SPOT_80W_RANGES = {
    strobe: [16, 251],
  }

  # 13ch mode chart from the vendor manual, cross checked on the bench
  # in M0-M2c (pan 1, dimmer 6, strobe below 16 steady, color 0 white,
  # gobo 0 open).
  SHEHDS_SPOT_80W_13CH = Personality.new(
    name: "SHEHDS Spot 80W 13ch",
    channels: 13,
    map: {
      pan: 1, pan_fine: 2, tilt: 3, tilt_fine: 4, speed: 5,
      dimmer: 6, strobe: 7, color: 8, gobo: 9, focus: 10,
      prism: 11, motor_auto: 12, function: 13,
    },
    tables: SHEHDS_SPOT_80W_TABLES,
    ranges: SHEHDS_SPOT_80W_RANGES,
  )

  # 10ch mode of the same fixture (menu chnd). Not used by the default
  # rig; defined for completeness from the same manual.
  SHEHDS_SPOT_80W_10CH = Personality.new(
    name: "SHEHDS Spot 80W 10ch",
    channels: 10,
    map: {
      pan: 1, tilt: 2, dimmer: 3, strobe: 4, color: 5,
      gobo: 6, focus: 7, prism: 8, speed: 9, function: 10,
    },
    tables: SHEHDS_SPOT_80W_TABLES,
    ranges: SHEHDS_SPOT_80W_RANGES,
  )

  # Default rig: two SHEHDS Spot 80W in 13ch mode, daisy chained.
  # Fixture body addresses must match the patch: s1 = 001, s2 = 014.
  def self.default_patch
    patch = Patch.new
    patch.add(:s1, SHEHDS_SPOT_80W_13CH, base: 1)
    patch.add(:s2, SHEHDS_SPOT_80W_13CH, base: 14)
    patch.group(:all, :s1, :s2)
    patch
  end

  def self.patch
    @patch ||= default_patch
  end

  def self.patch=(patch)
    @patch = patch
  end

  # Resolve a fixture or group by name: Johakyu.dmx(:s1).pan(0.5).
  def self.dmx(name)
    target = patch[name]
    unless target
      raise ArgumentError, "unknown fixture or group #{name}"
    end
    target
  end
end
