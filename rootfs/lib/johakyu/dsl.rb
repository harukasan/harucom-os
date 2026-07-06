# Johakyu stage A DSL: array step sequencer driving sound and light
# from one clock (research 05).
#
#   session = Johakyu::Session.new(audio: Board::PWMAudio.new, bpm: 120)
#   session.seq(:bd, [1, 0, 0, 0, 1, 0, 0, 0])
#   session.dmx_seq(:all, :dimmer, [1.0, 0, 0, 0, 1.0, 0, 0, 0])
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
require "johakyu/clock"
require "johakyu/scheduler"
require "johakyu/fixture"

module Johakyu
  class Session
    attr_reader :clock, :scheduler

    # Voice table: name -> [channel, frequency, waveform, gate_ms].
    # Tone-based stand-ins until WAV playback lands (M5).
    VOICES = {
      bd: [0, 65, :square, 90],
      sn: [1, 240, :triangle, 60],
      hh: [2, 2200, :square, 25],
    }

    def initialize(audio: nil, bpm: 120)
      @clock = Clock.new(bpm: bpm)
      @scheduler = Scheduler.new(@clock)
      @audio = audio
      @gates = []
    end

    def tempo(bpm)
      @clock.bpm = bpm
    end

    # Sound step track: seq(:bd, [1, 0, 0.5, 0]). Values scale volume.
    def seq(name, steps)
      pattern = Session.steps_to_pattern(steps, true)
      voice = VOICES[name] || VOICES[:bd]
      track = ("sound_" + name.to_s).to_sym
      @scheduler.bind(track, pattern) do |value, at_ms|
        trigger_voice(voice, value, at_ms)
      end
    end

    # Light step track: dmx_seq(:all, :dimmer, [1.0, 0, 0.5, 0]).
    # Integer steps write raw 0-255, Floats are normalized 0.0-1.0,
    # Symbols use the personality name tables.
    def dmx_seq(target, attribute, steps)
      pattern = Session.steps_to_pattern(steps, false)
      fixture = Johakyu.dmx(target)
      track = ("dmx_" + target.to_s + "_" + attribute.to_s).to_sym
      @scheduler.bind(track, pattern) do |value, _at_ms|
        write_dmx(fixture, attribute, value)
      end
    end

    # Continuous light track: dmx_signal(:all, :pan, Johakyu.sine.slow(4)).
    # Sampled once per tick; DMX frames quantize the rest.
    def dmx_signal(target, attribute, pattern)
      fixture = Johakyu.dmx(target)
      track = ("dmx_" + target.to_s + "_" + attribute.to_s).to_sym
      @scheduler.bind_continuous(track, pattern) do |value, _at_ms|
        write_dmx(fixture, attribute, value)
      end
    end

    # Advance the scheduler, fire due events, release finished notes,
    # and keep the audio ring buffer filled. Call every loop iteration.
    def update
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

    def write_dmx(fixture, attribute, value)
      if value.is_a?(Integer)
        fixture.raw(attribute, value)
      else
        fixture.set(attribute, value)
      end
    end
  end
end
