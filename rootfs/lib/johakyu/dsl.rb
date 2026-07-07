# Johakyu DSL: sound and light patterns driven from one clock
# (research 05, stages A to C).
#
#   session = Johakyu::Session.new(audio: Board::PWMAudio.new, bpm: 120)
#   session.seq(:bd, [1, 0, 0, 0, 1, 0, 0, 0])            # stage A
#   session.sound("bd*4, hh*8").every(4) { |p| p.fast(2) } # stages B/C
#   session.dmx(:s1).dimmer("1 0 0.5 0").color("<red blue>")
#   session.dmx(:s2).pan(Johakyu.sine.range(0.2, 0.8).slow(8))
#   loop do
#     session.update
#     DMX.keepalive
#     sleep_ms 10
#   end
#
# Steps become a fastcat Pattern (one cycle per array), so the same
# tracks accept mini notation and pattern transforms in later stages
# without changing the scheduler. Sound steps treat 0/nil as rests;
# DMX steps treat nil as a rest but 0 as a real value (a dimmer step
# of 0 turns the light off at that step).

require "johakyu/pattern"
require "johakyu/signal"
require "johakyu/mini"
require "johakyu/clock"
require "johakyu/scheduler"
require "johakyu/fixture"

module Johakyu
  class Session
    attr_reader :clock, :scheduler

    # Voice table: name -> [channel, frequency, waveform, gate_ms].
    # Tone-based stand-ins until WAV playback lands (M5). The kick sits
    # at 110 Hz: small speakers barely reproduce anything lower, and an
    # inaudible kick makes the light look off-beat.
    VOICES = {
      bd: [0, 110, :square, 90],
      sn: [1, 240, :triangle, 60],
      hh: [2, 2200, :square, 25],
    }

    # audio_latency_ms compensates the PWM audio output path: tone()
    # becomes audible only after the ring buffer (1024 samples, about
    # 46 ms) drains, while a DMX write lands within one 25 ms frame.
    # Sound events therefore fire early by this amount so beats and
    # light land together. The default was calibrated by ear against
    # the SHEHDS rig (the fixture dimmer adds its own lag, so the best
    # value sits below the raw buffer delay). Tune per venue with
    # audio_latency_ms=.
    def initialize(audio: nil, bpm: 120, audio_latency_ms: 20)
      @clock = Clock.new(bpm: bpm)
      @scheduler = Scheduler.new(@clock)
      @audio = audio
      @audio_latency_ms = audio_latency_ms
      @sound_tracks = []
      @gates = []
      @sound_pattern = nil
      @sound_dirty = false
    end

    attr_reader :audio_latency_ms

    # Adjust the sound output latency compensation at runtime and
    # restage so upcoming events use the new offset.
    def audio_latency_ms=(ms)
      ms = 0 if ms < 0
      @audio_latency_ms = ms
      i = 0
      while i < @sound_tracks.length
        @scheduler.set_latency(@sound_tracks[i], ms)
        i += 1
      end
      @scheduler.restage
    end

    def tempo(bpm)
      @clock.bpm = bpm
      # Staged target times were computed under the old tempo; drop and
      # restage so upcoming events land on the new grid.
      @scheduler.restage
    end

    # Sound step track: seq(:bd, [1, 0, 0.5, 0]). Values scale volume.
    def seq(name, steps)
      pattern = Session.steps_to_pattern(steps, true)
      voice = VOICES[name] || VOICES[:bd]
      track = ("sound_" + name.to_s).to_sym
      @sound_tracks << track unless @sound_tracks.include?(track)
      @scheduler.bind(track, pattern, latency_ms: @audio_latency_ms) do |value, at_ms|
        trigger_voice(voice, value, at_ms)
      end
    end

    # Light step track: dmx_seq(:all, :dimmer, [1.0, 0, 0.5, 0]).
    # Integer steps write raw 0-255, Floats are normalized 0.0-1.0,
    # Symbols use the personality name tables.
    def dmx_seq(target, attribute, steps)
      bind_dmx(target, attribute, Session.steps_to_pattern(steps, false))
    end

    # Continuous light track: dmx_signal(:all, :pan, Johakyu.sine.slow(4)).
    # Kept as the stage A name; bind_dmx detects signals itself, so
    # this is the same binding as dmx(target).pan(...).
    def dmx_signal(target, attribute, pattern)
      bind_dmx(target, attribute, pattern)
    end

    # Stage B/C: sound("bd ~ sn ~") plays named voices from mini
    # notation (or any Pattern). Values are voice names; "bd:2" style
    # sample numbers are accepted and the number is ignored until WAV
    # lands. Returns a handle so pattern transforms chain after the
    # call, Strudel style:
    #
    #   sound("bd*4").every(4) { |p| p.fast(2) }
    #
    # The bind is deferred to the next update so a transform chain
    # replaces the track once, with the final pattern. Binding per
    # link would play the untransformed pattern for the first cycle.
    def sound(pattern)
      @sound_pattern = Pattern.reify(pattern)
      @sound_dirty = true
      SoundHandle.new(self)
    end

    # Apply one transform to the pending sound pattern (SoundHandle
    # chain links call this).
    def transform_sound(&block)
      return unless @sound_pattern
      @sound_pattern = block.call(@sound_pattern)
      @sound_dirty = true
    end

    # Stage B: dmx(:s1).color("red blue").dimmer("1 0 0.5 0") binds
    # fixture attributes to mini notation (or any Pattern). Track names
    # match dmx_seq, so both styles swap over each other.
    def dmx(target)
      DmxTarget.new(self, target)
    end

    # Bind one fixture attribute track. Continuous patterns (signals)
    # are sampled every tick, discrete patterns are staged as events,
    # so dmx(:s1).pan(Johakyu.sine.slow(8)) and dmx(:s1).pan("0 0.5")
    # go through the same call. Used by dmx_seq, dmx_signal, DmxTarget.
    def bind_dmx(target, attribute, pattern)
      fixture = Johakyu.dmx(target)
      track = ("dmx_" + target.to_s + "_" + attribute.to_s).to_sym
      if pattern.continuous?
        @scheduler.bind_continuous(track, pattern) do |value, _at_ms|
          Session.write_dmx(fixture, attribute, value)
        end
      else
        @scheduler.bind(track, pattern) do |value, _at_ms|
          Session.write_dmx(fixture, attribute, value)
        end
      end
    end

    # Chainable per-target binder returned by Session#dmx.
    class DmxTarget
      def initialize(session, target)
        @session = session
        @target = target
      end

      def pan(pattern)
        bind(:pan, pattern)
      end

      def tilt(pattern)
        bind(:tilt, pattern)
      end

      def dimmer(pattern)
        bind(:dimmer, pattern)
      end

      def strobe(pattern)
        bind(:strobe, pattern)
      end

      def color(pattern)
        bind(:color, pattern)
      end

      def gobo(pattern)
        bind(:gobo, pattern)
      end

      def focus(pattern)
        bind(:focus, pattern)
      end

      def prism(pattern)
        bind(:prism, pattern)
      end

      def speed(pattern)
        bind(:speed, pattern)
      end

      private

      def bind(attribute, pattern)
        @session.bind_dmx(@target, attribute, Pattern.reify(pattern))
        self
      end
    end

    # Chainable transform handle returned by Session#sound. Each link
    # transforms the pending sound pattern; the next update binds the
    # final result once.
    class SoundHandle
      def initialize(session)
        @session = session
      end

      def fast(factor)
        transform { |p| p.fast(factor) }
      end

      def slow(factor)
        transform { |p| p.slow(factor) }
      end

      def rev
        transform { |p| p.rev }
      end

      def every(n, &func)
        transform { |p| p.every(n, &func) }
      end

      def euclid(pulses, steps, rotation = 0)
        transform { |p| p.euclid(pulses, steps, rotation) }
      end

      def struct(bool_pattern)
        transform { |p| p.struct(bool_pattern) }
      end

      def mask(bool_pattern)
        transform { |p| p.mask(bool_pattern) }
      end

      def degrade_by(amount)
        transform { |p| p.degrade_by(amount) }
      end

      def degrade
        transform { |p| p.degrade }
      end

      private

      def transform(&block)
        @session.transform_sound(&block)
        self
      end
    end

    # Advance the scheduler, fire due events, release finished notes,
    # and keep the audio ring buffer filled. Call every loop iteration.
    def update
      flush_sound if @sound_dirty
      @scheduler.tick
      @scheduler.pump
      pump_gates
      @audio.update if @audio
    end

    # Silence all voices (does not touch DMX).
    def stop_sounds
      @gates = []
      @audio.stop_all if @audio
    end

    # Resolve one event value onto a fixture attribute. Integers are
    # raw 0-255, Floats are normalized, Symbols use the name tables.
    # Strings come from mini notation: numeric text ("0.5") becomes a
    # normalized Float, anything else is a table name ("red").
    # Booleans come from structure patterns like euclid: full or zero.
    def self.write_dmx(fixture, attribute, value)
      if value.is_a?(String)
        if numeric_string?(value)
          fixture.set(attribute, value.to_f)
        else
          fixture.set(attribute, value)
        end
      elsif value.is_a?(Integer)
        fixture.raw(attribute, value)
      elsif value == true
        fixture.set(attribute, 1.0)
      elsif value == false
        fixture.set(attribute, 0.0)
      else
        fixture.set(attribute, value)
      end
    end

    def self.numeric_string?(text)
      digits = false
      i = 0
      while i < text.length
        ch = text[i]
        if ch >= "0" && ch <= "9"
          digits = true
        elsif ch != "."
          return false
        end
        i += 1
      end
      digits
    end

    def self.steps_to_pattern(steps, zero_is_rest)
      items = []
      i = 0
      while i < steps.length
        value = steps[i]
        if value.nil? || (zero_is_rest && value == 0)
          items << Pattern.silence
        else
          items << Pattern.pure(value)
        end
        i += 1
      end
      Pattern.fastcat(*items)
    end

    private

    # Bind the pending sound pattern to the :sound track. Rebinding an
    # existing track swaps at the next cycle boundary (scheduler rule),
    # so live edits land musically.
    def flush_sound
      @sound_dirty = false
      pattern = @sound_pattern
      @sound_tracks << :sound unless @sound_tracks.include?(:sound)
      @scheduler.bind(:sound, pattern, latency_ms: @audio_latency_ms) do |value, at_ms|
        name = value.is_a?(Hash) ? value[:s] : value
        name = name.to_sym if name.is_a?(String)
        voice = VOICES[name]
        trigger_voice(voice, 1.0, at_ms) if voice
      end
    end

    def trigger_voice(voice, value, at_ms)
      return unless @audio
      level = value == true ? 1.0 : value.to_f
      level = 0.0 if level < 0.0
      level = 1.0 if level > 1.0
      volume = (level * 15.0 + 0.5).to_i
      return if volume == 0
      channel = voice[0]
      # Drop any pending gate for this channel so a stale note-off
      # cannot silence the note we are about to start.
      i = 0
      while i < @gates.length
        if @gates[i][1] == channel
          @gates.delete_at(i)
        else
          i += 1
        end
      end
      @audio.tone(channel, voice[1], waveform: waveform(voice[2]), volume: volume)
      # Gate from the actual start time, not the scheduled target. When
      # the event fires late (GC or a slow loop iteration), a gate based
      # on at_ms would already be due and stop the note immediately.
      now = Machine.board_millis
      start = at_ms > now ? at_ms : now
      @gates << [start + voice[3], channel]
    end

    def pump_gates
      now = Machine.board_millis
      i = 0
      while i < @gates.length
        gate = @gates[i]
        if gate[0] <= now
          @gates.delete_at(i)
          @audio.stop(gate[1])
        else
          i += 1
        end
      end
    end

    def waveform(name)
      case name
      when :sine then ::PWMAudio::SINE
      when :triangle then ::PWMAudio::TRIANGLE
      when :sawtooth then ::PWMAudio::SAWTOOTH
      else ::PWMAudio::SQUARE
      end
    end
  end
end
