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

    # One entry per drum voice: mixer channel, bank slot, and sample
    # source. Tones use channels 0-2; drums one-shot on 3-7. Pairs share
    # a channel to choke each other (hh/oh, cp/rim, lt/ht) but keep
    # their own bank slot, so the shared channel plays the right sample
    # and the retrigger cuts the previous one. :sn aliases :sd (same
    # slot and source). The mini ":n" suffix is a sample-variation
    # number, unrelated to :slot; play_sound still ignores it.
    KIT = {
      bd:  { channel: 3, slot: 0, source: "bd" },
      sd:  { channel: 4, slot: 1, source: "sd" },
      sn:  { channel: 4, slot: 1, source: "sd" },
      hh:  { channel: 5, slot: 2, source: "hh" },
      oh:  { channel: 5, slot: 3, source: "oh" },
      cp:  { channel: 6, slot: 4, source: "cp" },
      rim: { channel: 6, slot: 5, source: "rim" },
      lt:  { channel: 7, slot: 6, source: "lt" },
      ht:  { channel: 7, slot: 7, source: "ht" },
    }
    KIT_VOLUME = 14

    # Tone voices for pitched notes; drums own channels 3-7. Notes
    # round-robin across the pool and steal the channel's previous
    # reservation when they overlap it.
    TONE_CHANNELS = [0, 1, 2]
    NOTE_VOLUME = 12

    # Equal temperament for octave 9 (c9..b9 in the c5 = 60 naming).
    # Lower octaves derive by integer halving with rounding, so pitch
    # never touches Float.
    NOTE_BASE_HZ = [4186, 4435, 4699, 4978, 5274, 5588, 5920, 6272,
                    6645, 7040, 7459, 7902]

    # Waveform names accepted from .sound() on note tracks live in
    # the lazily built waveforms map: referencing ::PWMAudio at file
    # load or in initialize would break embedders without the audio
    # module (the CRuby test discovery pass, the host bench).

    # Sinks fire this many ms before their musical target. Sound is
    # reserved in C for the target sample and light writes wait in the
    # due list until the target, so a fire delayed by up to this lead
    # still lands on time. The lead therefore bounds the staging stall
    # the output absorbs (board preset 5 stages up to ~80 ms); only a
    # delay beyond the lead reaches the output, counted by
    # output_late_count. The cost of a larger lead: a quantized track
    # swap leaks at most this much of the old pattern into the new
    # cycle.
    # 300 ms budgets for the bumped VM with the interpreter pinned in
    # SRAM: the busiest preset still fires up to roughly 276 ms after
    # target on the board, so 250 ms leaked single events.
    RESERVE_LEAD_MS = 300

    # The audio engine renders at a fixed 50 kHz (PWMAudio::SAMPLE_RATE).
    SAMPLES_PER_MS = 50

    def initialize(audio: nil, bpm: 120, audio_latency_ms: 0)
      @clock = Clock.new(bpm: bpm)
      @scheduler = Scheduler.new(@clock)
      @audio = audio
      @audio_latency_ms = audio_latency_ms
      @light_pending = []
      @output_late_count = 0
      @output_late_ms_max = 0
      @light_error = nil
      @next_voice = 0
      @voice_busy_until = Array.new(TONE_CHANNELS.length, 0)
      @note_drop_count = 0
    end

    # Notes whose C-engine reservation was refused (the shared
    # scheduled-event queue holds 32 slots across all channels).
    attr_reader :note_drop_count

    # Events whose fire delay exceeded RESERVE_LEAD_MS, so the overrun
    # reached the output (sound clamped to now, light written late).
    # This is the musically honest late measure; the scheduler's
    # fire_delay_ms_max only covers queue lateness after staging.
    attr_reader :output_late_count, :output_late_ms_max

    # Last per-write light failure (an unknown color name and the
    # like). Event-time raises must not escape: they would cross the
    # eval isolation and take the whole show loop down, so the write
    # is dropped, the rest of the event still lands, and the message
    # waits here for the UI.
    attr_reader :light_error

    def reset_stats
      @scheduler.reset_stats
      @output_late_count = 0
      @output_late_ms_max = 0
      @note_drop_count = 0
    end

    # Fine alignment trim between sound and light, in ms; positive
    # values move sound earlier. Reservations are sample accurate, so
    # this only compensates the light path (DMX frame quantization and
    # fixture response). Tune per venue.
    attr_accessor :audio_latency_ms

    # Preload the drum samples into their bank slots on the real engine.
    # Loads /data/drums WAVs; a missing or unreadable file falls back to
    # rendering the same Synth definition on the board. Each distinct
    # source loads once; @sample_bank_pin holds the bytes so the engine
    # pointer stays valid for the Session's life.
    def load_kit
      return unless @audio
      @sample_bank_pin ||= []
      KIT.each_value do |entry|
        slot = entry[:slot]
        next if @sample_bank_pin[slot]
        data = load_drum_data(entry[:source])
        @audio.load_sample(slot, data)
        @sample_bank_pin[slot] = data
      end
    end

    # Read a drum WAV from /data/drums, or synthesize it on the board
    # when the file is missing or unreadable (File.open returns nil for
    # missing files instead of raising).
    def load_drum_data(source)
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
      data
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
      @scheduler.bind(name, pattern, latency_ms: lead) do |value, early_ms, duration_ms|
        dispatch_event(value, early_ms + lead, duration_ms)
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

    # Fire due sinks without staging. Call between two heavy blocking
    # operations in the app loop (a syntax parse, a full redraw), so
    # their costs never chain into one pump gap longer than the lead.
    def pump_outputs
      @scheduler.pump
      pump_lights
    end

    # Build extra staged runway across all tracks, pumping due events
    # between chunks. Call right before a known blocking stall (the
    # eval compile) and right after an apply rebinds tracks, so the
    # stall or burst is paid from pre-staged events instead of firing
    # late.
    def prestage(cycles = 0.75, budget_ms = 250)
      @scheduler.stage_ahead(cycles, budget_ms) { pump_outputs }
    end

    # Silence all voices (does not touch DMX).
    def stop_sounds
      @audio.stop_all if @audio
    end

    # Split one control map into the two sinks. Sound reserves now for
    # the target; light waits in the due list until the target.
    def dispatch_event(value, target_ms, duration_ms = nil)
      overrun = Machine.board_millis - target_ms
      if overrun > 0
        @output_late_count += 1
        @output_late_ms_max = overrun if overrun > @output_late_ms_max
      end
      map = value.is_a?(Hash) ? value : { s: value }
      if map[:note]
        # A note map may carry :s as its waveform name; the pitched
        # path consumes it, so it never reaches the drum kit.
        play_note(map, target_ms, duration_ms)
      elsif map[:s]
        play_sound(map[:s], target_ms)
      end

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
      # Untargeted light controls default to the :all group of the
      # running rig, resolved per event so a patch swap redirects
      # immediately; without a rig the write is dropped, Tidal style.
      target = map[:target] || Johakyu.patch[:all]
      return if target.nil?
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
    # together. The bank slot rides on the reservation so a shared
    # channel plays the right sample even when a neighbor is reserved
    # first. Unknown names are ignored, Tidal style. The ":n" suffix is
    # a sample-variation number, unrelated to the bank slot, so it is
    # dropped here.
    def play_sound(name, target_ms)
      return unless @audio
      name = name.to_s
      colon = name.index(":")
      name = name[0, colon] if colon
      entry = KIT[name.to_sym]
      return unless entry
      target = target_ms - @audio_latency_ms
      now_ms = Machine.board_millis
      at_sample = @audio.sample_clock + (target - now_ms) * SAMPLES_PER_MS
      at_sample = @audio.sample_clock if at_sample < @audio.sample_clock
      @audio.play_at(at_sample, entry[:channel], KIT_VOLUME, entry[:slot])
    end

    # Reserve one pitched note: a tone at the target sample and a
    # stop at the note's end (the hap whole duration threaded through
    # the scheduler). Voices round-robin over TONE_CHANNELS; a note
    # overlapping the channel's previous reservation steals it, which
    # drops the stale stop and, if the old note had not sounded yet,
    # its start.
    def play_note(map, target_ms, duration_ms)
      return unless @audio
      number = map[:note]
      return unless number.is_a?(Integer)
      duration_ms = 125 if duration_ms.nil? || duration_ms <= 0
      target = target_ms - @audio_latency_ms
      now_ms = Machine.board_millis
      base = @audio.sample_clock
      at_sample = base + (target - now_ms) * SAMPLES_PER_MS
      at_sample = base if at_sample < base
      stop_sample = at_sample + duration_ms * SAMPLES_PER_MS

      index = @next_voice
      @next_voice = index + 1 >= TONE_CHANNELS.length ? 0 : index + 1
      channel = TONE_CHANNELS[index]
      @audio.cancel_scheduled(channel) if at_sample < @voice_busy_until[index]

      waveform = waveforms[map[:s]]
      waveform = ::PWMAudio::SQUARE if waveform.nil?
      gain = map[:gain]
      if gain
        volume = (gain.to_f * 15).to_i
        volume = 0 if volume < 0
        volume = 15 if volume > 15
      else
        volume = NOTE_VOLUME
      end
      ok = @audio.tone_at(at_sample, channel, note_hz(number),
                          waveform: waveform, volume: volume)
      ok = @audio.stop_at(stop_sample, channel) && ok
      @note_drop_count += 1 unless ok
      @voice_busy_until[index] = stop_sample
    end

    def waveforms
      @waveforms ||= {
        "sine" => ::PWMAudio::SINE, :sine => ::PWMAudio::SINE,
        "square" => ::PWMAudio::SQUARE, :square => ::PWMAudio::SQUARE,
        "tri" => ::PWMAudio::TRIANGLE, :tri => ::PWMAudio::TRIANGLE,
        "triangle" => ::PWMAudio::TRIANGLE, :triangle => ::PWMAudio::TRIANGLE,
        "saw" => ::PWMAudio::SAWTOOTH, :saw => ::PWMAudio::SAWTOOTH,
        "sawtooth" => ::PWMAudio::SAWTOOTH, :sawtooth => ::PWMAudio::SAWTOOTH,
      }
    end

    # Integer Hz for a note number: shift the octave-9 table down
    # with rounding. Note that this naming sits one octave above the
    # Board::PWMAudio constants (c5 = 60 = 262 Hz = Board's C4).
    def note_hz(number)
      number = 0 if number < 0
      number = 119 if number > 119
      pitch = number % 12
      shift = 9 - number / 12
      return NOTE_BASE_HZ[pitch] if shift <= 0
      (NOTE_BASE_HZ[pitch] + (1 << (shift - 1))) >> shift
    end

    def pump_lights
      now = Machine.board_millis
      kept = 0
      i = 0
      while i < @light_pending.length
        event = @light_pending[i]
        i += 1
        if event[0] <= now
          fixture = event[1]
          writes = event[2]
          j = 0
          while j < writes.length
            begin
              Session.write_dmx(fixture, writes[j], writes[j + 1])
            rescue => e
              @light_error = "#{e.message} (#{e.class})"
            end
            j += 2
          end
        else
          @light_pending[kept] = event
          kept += 1
        end
      end
      @light_pending.pop while @light_pending.length > kept
    end
  end
end
