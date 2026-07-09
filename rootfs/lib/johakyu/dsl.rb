# Johakyu Session: the all-pattern dispatcher. Every statement is a
# Pattern of control maps (see control.rb); one query drives both
# sinks. Sound controls (:s) become sample-accurate reservations on
# the C audio engine; light controls become fixture writes at their
# target frame time.
#
#   session = Johakyu::Session.new(audio: Board::PWMAudio.new, bpm: 120)
#   session.load_kit
#   session.bind_statement(:drums, Johakyu.sound("bd*4").color("<red blue>"))
#   loop do
#     session.update
#     DMX.keepalive
#     sleep_ms 10
#   end
#
# Timing: the scheduler stages events and fires each statement's sink
# RESERVE_LEAD_MS early. The dispatcher converts the musical target
# time to a sample offset (board_millis and sample_clock read as an
# anchor pair) and reserves the sound in C, so playback lands sample
# accurate regardless of loop jitter. Light writes wait in a small due
# list and land on their target time with loop granularity, well
# inside one 25 ms DMX frame.

require "johakyu/pattern"
require "johakyu/signal"
require "johakyu/mini"
require "johakyu/control"
require "johakyu/clock"
require "johakyu/scheduler"
require "johakyu/fixture"

module Johakyu
  class Session
    attr_reader :clock, :scheduler

    # Drum kit channel map, matching audio_demo: tones would use 0-2,
    # drums one-shot on 3-7. Pairs sharing a channel cut each other
    # off (hh/oh is the hihat choke). :sn aliases :sd so mini patterns
    # written either way play.
    KIT_CHANNELS = {
      bd: 3, sd: 4, sn: 4, hh: 5, oh: 5,
      cp: 6, rim: 6, lt: 7, ht: 7,
    }
    KIT_SOURCES = {
      bd: "bd", sd: "sd", sn: "sd", hh: "hh", oh: "oh",
      cp: "cp", rim: "rim", lt: "lt", ht: "ht",
    }
    KIT_VOLUME = 14

    # Sinks fire this many ms before their musical target. Sound is
    # reserved in C for the target sample and light writes wait in the
    # due list until the target, so a fire delayed by up to this lead
    # still lands on time. The lead therefore bounds the staging stall
    # the output absorbs (board preset 5 stages up to ~80 ms); only a
    # delay beyond the lead reaches the output, counted by
    # output_late_count. The cost of a larger lead: a quantized track
    # swap leaks at most this much of the old pattern into the new
    # cycle.
    RESERVE_LEAD_MS = 120

    # The audio engine renders at a fixed 50 kHz (PWMAudio::SAMPLE_RATE).
    SAMPLES_PER_MS = 50

    def initialize(audio: nil, bpm: 120, audio_latency_ms: 0)
      @clock = Clock.new(bpm: bpm)
      @scheduler = Scheduler.new(@clock)
      @audio = audio
      @audio_latency_ms = audio_latency_ms
      @light_pending = []
      @default_target = nil
      @output_late_count = 0
      @output_late_ms_max = 0
    end

    # Events whose fire delay exceeded RESERVE_LEAD_MS, so the overrun
    # reached the output (sound clamped to now, light written late).
    # This is the musically honest late measure; the scheduler's
    # fire_delay_ms_max includes delays the lead absorbed.
    attr_reader :output_late_count, :output_late_ms_max

    def reset_stats
      @scheduler.reset_stats
      @output_late_count = 0
      @output_late_ms_max = 0
    end

    # Fine alignment trim between sound and light, in ms; positive
    # values move sound earlier. Reservations are sample accurate, so
    # this only compensates the light path (DMX frame quantization and
    # fixture response). Tune per venue.
    attr_accessor :audio_latency_ms

    # Attach the drum samples to their channels on the real engine.
    # Loads /data/drums WAVs; a missing or unreadable file falls back
    # to rendering the same Synth definition on the board (File.open
    # returns nil for missing files instead of raising).
    def load_kit
      return unless @audio
      attached = {}
      KIT_SOURCES.each do |name, source|
        next if attached[source]
        data = nil
        begin
          data = File.open("/data/drums/#{source}.wav", "r") { |f| f.read }
        rescue
          data = nil
        end
        if data.nil? || data.bytesize < 44
          require "synth/drum_kit"
          data = Synth::DrumKit.render(source)
        end
        channel = @audio.channel(KIT_CHANNELS[name])
        channel.source = ::PWMAudio::Sample.new(data)
        attached[source] = true
      end
    end

    def tempo(bpm)
      @clock.bpm = bpm
      # Staged target times were computed under the old tempo; drop and
      # restage so upcoming events land on the new grid.
      @scheduler.restage
    end

    # Bind one statement (a Pattern of control maps) to a named track.
    # Rebinding swaps at the next cycle boundary (scheduler rule).
    def bind_statement(name, pattern)
      lead = RESERVE_LEAD_MS
      @scheduler.bind(name, pattern, latency_ms: lead) do |value, early_ms|
        dispatch_event(value, early_ms + lead)
      end
    end

    def remove_statement(name)
      @scheduler.remove(name)
    end

    # Advance the scheduler, fire due sinks, and land due light writes.
    # Call every loop iteration. The audio engine renders autonomously
    # in C and needs no pumping from here.
    def update
      @scheduler.tick
      @scheduler.pump
      pump_lights
    end

    # Silence all voices (does not touch DMX).
    def stop_sounds
      @audio.stop_all if @audio
    end

    # Split one control map into the two sinks. Sound reserves now for
    # the target; light waits in the due list until the target.
    def dispatch_event(value, target_ms)
      overrun = Machine.board_millis - target_ms
      if overrun > 0
        @output_late_count += 1
        @output_late_ms_max = overrun if overrun > @output_late_ms_max
      end
      map = value.is_a?(Hash) ? value : { s: value }
      play_sound(map[:s], target_ms) if map[:s]

      writes = nil
      i = 0
      while i < LIGHT_CONTROLS.length
        key = LIGHT_CONTROLS[i]
        i += 1
        v = map[key]
        next if v.nil?
        writes = [] if writes.nil?
        writes << key
        writes << v
      end
      return if writes.nil?
      target = map[:target] || (@default_target ||= Johakyu.dmx(:all))
      @light_pending << [target_ms, target, writes]
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

    private

    # Reserve one drum hit in the C engine at the target time,
    # converted through a board_millis/sample_clock anchor pair read
    # together. Unknown names are ignored, Tidal style.
    def play_sound(name, target_ms)
      return unless @audio
      name = name.to_s
      colon = name.index(":")
      name = name[0, colon] if colon
      channel = KIT_CHANNELS[name.to_sym]
      return unless channel
      target = target_ms - @audio_latency_ms
      now_ms = Machine.board_millis
      at_sample = @audio.sample_clock + (target - now_ms) * SAMPLES_PER_MS
      at_sample = @audio.sample_clock if at_sample < @audio.sample_clock
      @audio.play_at(at_sample, channel, KIT_VOLUME)
    end

    def pump_lights
      now = Machine.board_millis
      i = 0
      while i < @light_pending.length
        event = @light_pending[i]
        if event[0] <= now
          @light_pending.delete_at(i)
          fixture = event[1]
          writes = event[2]
          j = 0
          while j < writes.length
            Session.write_dmx(fixture, writes[j], writes[j + 1])
            j += 2
          end
        else
          i += 1
        end
      end
    end
  end
end
