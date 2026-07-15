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
  # many steps per cycle. 8 steps (250 ms at 120 bpm) is the second
  # rung of the optimization ladder: each halving halves the staging
  # query cost of signal-driven tracks, and the fixtures smooth the
  # coarser moves. Use an explicit segment(n) where finer resolution
  # matters.
  SEGMENT_DEFAULT = 8

  # Build a structure source from mini notation, a Pattern, a Signal
  # (auto-segmented), or a plain value, with values wrapped into
  # control maps under key.
  def self.control_source(key, source)
    pattern = Pattern.reify(source)
    pattern = pattern.segment(SEGMENT_DEFAULT) if pattern.is_a?(Signal)
    pattern.fmap do |value|
      value.is_a?(Hash) ? value : { key => value }
    end
  end

  # Sound statement: values become {s: name} control maps. Mini
  # notation hashes pass through.
  def self.sound(source)
    control_source(:s, source)
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
