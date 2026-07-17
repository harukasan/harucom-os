# Control patterns: the all-pattern surface. Every statement is a
# Pattern whose values are control maps (Hash), carrying the sound key
# (:s) and light keys (fixture personality attributes plus :target).
# One query drives both sinks; the dispatcher in dsl.rb splits the map.
#
#   Johakyu.sound("bd*4").color("<red blue>")   # light rides the kick
#   Johakyu.pan(Johakyu.sine.slow(8)).on(:s1)   # standalone automation
#   Johakyu.dimmer("1 0").spread(0.5, on: :all) # chase across members
#
# Chaining attaches controls with structure from left (Tidal's #):
# dimmer("1 0").color("<red blue>") samples the colors at the dimmer's
# event times. Use two statements when the structures must stay
# independent.

require "johakyu/pattern"
require "johakyu/signal"
require "johakyu/mini"
require "johakyu/fixture"

module Johakyu
  # A bare Signal used as a structure source is discretized to this
  # many steps per cycle. 16 steps (125 ms at 120 bpm) rides on the
  # SignalControl fast path below, which queries a whole statement in
  # one layer; the fixtures smooth the remaining steps. Use an
  # explicit segment(n) where a different resolution matters.
  SEGMENT_DEFAULT = 16

  # Build a structure source from mini notation, a Pattern, a Signal
  # (auto-segmented), or a plain value, with values wrapped into
  # control maps under key.
  def self.control_source(key, source)
    pattern = Pattern.reify(source)
    return SignalControl.new(pattern, SEGMENT_DEFAULT, key) if pattern.is_a?(Signal)
    result = pattern.fmap do |value|
      value.is_a?(Hash) ? value : { key => value }
    end
    result.sig = pattern.sig && "ctl:#{key}(#{pattern.sig})"
    result
  end

  # Folded statement for a bare Signal: the segment discretization,
  # the {key => value} control wrap, and any constant controls (the
  # .on(:s1) target and friends) live in one pattern object, so a
  # statement like pan(sine.slow(8)).on(:s1) queries as a single
  # layer instead of stacking segment, fmap, and with_control.
  class SignalControl < SegmentedSignal
    def initialize(signal, n, key, statics = nil)
      super(signal, n)
      @key = key
      # Flat [key, value, ...] pairs merged into every control map.
      @statics = statics
      base = signal.sig
      if base
        s = "ctl:#{key}(seg:#{n}(#{base}))"
        if statics
          i = 0
          while i < statics.length
            s = s + ";" + statics[i].to_s + "=" + Pattern.sig_value(statics[i + 1])
            i += 2
          end
        end
        self.sig = s
      else
        self.sig = nil
      end
    end

    # Constants fold into the statics; pattern controls fall back to
    # the generic per-event sampling layer.
    def with_control(key, other)
      return super if other.is_a?(Pattern)
      statics = @statics ? @statics.dup : []
      statics << key << other
      SignalControl.new(@signal, @n, @key, statics)
    end

    private

    def value_at(position)
      map = { @key => @signal.sample(position) }
      statics = @statics
      if statics
        i = 0
        while i < statics.length
          map[statics[i]] = statics[i + 1]
          i += 2
        end
      end
      map
    end
  end

  # Sound statement: values become {s: name} control maps. Mini
  # notation hashes pass through.
  def self.sound(source)
    control_source(:s, source)
  end

  # Note name letters to pitch classes (c5 = 60, a5 = 69 = 440 Hz,
  # the strudel naming).
  NOTE_LETTERS = {
    "c" => 0, "d" => 2, "e" => 4, "f" => 5, "g" => 7, "a" => 9, "b" => 11,
  }

  # Note atom to note number, memoized so name parsing runs once per
  # unique atom and staging pays one Hash lookup per event.
  def self.note_number(value)
    return value if value.is_a?(Integer)
    return value.to_i if value.is_a?(Float)
    @note_numbers ||= {}
    cached = @note_numbers[value]
    return cached if cached
    @note_numbers[value] = parse_note(value)
  end

  # "c5", "c#5" or "cs5" (sharp), "eb3" (flat; the first character is
  # always the letter, so "b3" is the note B), uppercase accepted,
  # numeric text passes through, octave defaults to 5.
  def self.parse_note(text)
    ch = text[0]
    raise ArgumentError, "unknown note '#{text}'" if ch.nil?
    ch = (ch.ord + 32).chr if ch >= "A" && ch <= "Z"
    return text.to_i if ch >= "0" && ch <= "9"
    pitch = NOTE_LETTERS[ch]
    raise ArgumentError, "unknown note '#{text}'" if pitch.nil?
    i = 1
    while i < text.length
      c = text[i]
      if c == "#" || c == "s"
        pitch += 1
        i += 1
      elsif c == "b"
        pitch -= 1
        i += 1
      else
        break
      end
    end
    octave = 5
    if i < text.length
      j = i
      while j < text.length
        c = text[j]
        raise ArgumentError, "unknown note '#{text}'" unless c >= "0" && c <= "9"
        j += 1
      end
      octave = text[i, text.length - i].to_i
    end
    12 * octave + pitch
  end

  # Note statement: values become {note: number} control maps, the
  # pitched analogue of sound(). Chords come from mini stacks like
  # "[c5,e5,g5]". Chain .sound("saw") for the waveform and
  # .gain(0..1) for the volume.
  def self.note(source)
    pattern = Pattern.reify(source)
    pattern = pattern.segment(SEGMENT_DEFAULT) if pattern.is_a?(Signal)
    result = pattern.fmap do |value|
      value.is_a?(Hash) ? value : { note: note_number(value) }
    end
    result.sig = pattern.sig && "note(#{pattern.sig})"
    result
  end

  # One statement builder per light control: Johakyu.pan(source) etc.
  LIGHT_CONTROLS.each do |key|
    define_singleton_method(key) { |source| control_source(key, source) }
  end

  # Target sugar: dmx(:s1).dimmer("1 0") == dimmer("1 0").on(:s1).
  # Returns Patterns, so further chaining attaches controls with
  # structure from left. (Johakyu.dmx itself stays the fixture
  # resolver; the live layer's top-level dmx() calls this.)
  def self.dmx_builder(target)
    ControlBuilder.new(target)
  end

  class ControlBuilder
    def initialize(target)
      Johakyu.dmx(target) # unknown fixtures fail at build time
      @target = target
    end

    LIGHT_CONTROLS.each do |key|
      define_method(key) { |source| build(key, source) }
    end

    private

    def build(key, source)
      Johakyu.control_source(key, source).on(@target)
    end
  end

  # Control attachment methods on every Pattern.
  class Pattern
    # Route light controls to a fixture or group. The resolved object
    # rides in the control map, so unknown names fail at build time
    # and the dispatcher does no lookup per event.
    def on(target)
      on_resolved(Johakyu.dmx(target))
    end

    def on_resolved(fixture_or_group)
      with_control(:target, fixture_or_group)
    end

    # Chained controls sample at this pattern's event times (structure
    # from left); one method per light control.
    LIGHT_CONTROLS.each do |key|
      define_method(key) { |source| attach_control(key, source) }
    end

    # Chained sound controls, the same structure-from-left shape: the
    # waveform name for note tracks and the volume 0..1.
    def sound(source)
      attach_control(:s, source)
    end

    def gain(source)
      attach_control(:gain, source)
    end

    # Duplicate this pattern across the members of a group, each copy
    # targeted at one member and shifted late by amount * i / (n - 1)
    # cycles (the chase distribution used by fixture spreads).
    def spread(amount, on: :all)
      members = Johakyu.spread_members(on)
      return self.on_resolved(members[0]) if members.length < 2
      copies = []
      i = 0
      while i < members.length
        offset = amount.to_f * i / (members.length - 1)
        copies << self.on_resolved(members[i]).late(offset)
        i += 1
      end
      Pattern.stack(*copies)
    end

    private

    # Chained controls sample at this pattern's event times (structure
    # from left). Strings are mini notation; other values pass to
    # with_control as patterns or constants.
    def attach_control(key, source)
      source = Johakyu.mini(source) if source.is_a?(String)
      with_control(key, source)
    end
  end

  # Member fixtures of a group target, for spread. A plain fixture
  # spreads onto itself.
  def self.spread_members(target)
    resolved = Johakyu.dmx(target)
    resolved.is_a?(Group) ? resolved.members : [resolved]
  end
end
