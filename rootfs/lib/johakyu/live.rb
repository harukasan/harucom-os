# Johakyu live coding layer: pure recording of an eval script, applied
# to the running session afterwards (research 06/08).
#
# The johakyu app evaluates the editor buffer in a resident Sandbox
# task. That task must not touch the running Session directly: the
# scheduler arrays are mutated by the app task on every update, and a
# preemptive task switch mid-mutation would corrupt them. Instead the
# script talks to a Live recorder through top-level DSL methods, which
# only build Patterns and record intents, both side-effect free. When
# the sandbox finishes cleanly the app task calls Live#apply, which
# replays the recording onto the Session; the scheduler's quantized
# swap makes the change land at the next cycle boundary. If the script
# raised, the recording is discarded and the show keeps playing.
#
# Statements are tracks (the DAW model). track(:name) { pattern }
# names one; a bare statement takes the next anonymous slot :t1, :t2
# in order of appearance. _track(:name) mutes without deleting, the
# strudel-rb idiom. Each eval describes the whole desired state:
# tracks bound by a previous apply but absent from the new recording
# are removed, so an empty buffer silences everything.
#
# The rig is patched from the script too: fixture/group statements
# build a pending patch (personalities load from the OFL definitions
# under /data/dmx/fixtures), and later statements resolve against it,
# so one eval can patch fixtures and target them. Put the fixture
# lines first. A script without fixture statements keeps the current
# rig; the patch is infrastructure, not a track.
#
#   fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
#   group :all, :s1
#   tempo 130
#   track(:drums) { sound("bd*2 [~ sd] bd sd, hh*8").color("<red blue>") }
#   _track(:wash) { dimmer(sine.slow(4)).on(:all) }
#   pan(sine.range(0.3, 0.7).slow(8)).on(:s2)      # anonymous :t1

require "johakyu/dsl"
require "johakyu/control"

module Johakyu
  class Live
    attr_reader :session

    def initialize(session)
      @session = session
      @recording = nil
      @applied = {}
      @capturing = 0
    end

    # Start a fresh recording. Call from the app task right before
    # executing the eval script.
    def begin_recording
      @recording = { tempo: nil, latency: nil, tracks: [], patch: nil }
      @capturing = 0
      Johakyu.build_patch = nil
    end

    def recording?
      @recording != nil
    end

    # Drop the recording without applying (script raised or timed out).
    def discard
      @recording = nil
      Johakyu.build_patch = nil
    end

    # -- Recorder side: called from the eval script (sandbox task). --
    # These only validate and record; nothing reaches the Session.

    def tempo(bpm)
      @recording[:tempo] = bpm
    end

    def audio_latency(ms)
      @recording[:latency] = ms
    end

    # Patch one fixture into the pending rig. The first fixture
    # statement starts a fresh patch and makes it the resolution
    # context, so the rest of the script targets the new rig.
    def fixture(name, file, mode: nil, address:)
      pending = @recording[:patch]
      unless pending
        pending = Patch.new
        @recording[:patch] = pending
        Johakyu.build_patch = pending
      end
      pending.add(name, Johakyu.personality(file, mode), base: address)
    end

    # Define a group over fixtures patched above.
    def group(name, *members)
      pending = @recording[:patch]
      unless pending
        raise ArgumentError, "group needs fixture statements before it"
      end
      pending.group(name, *members)
    end

    # Named track: the block builds and returns a Pattern. Sugar
    # called inside the block returns plain Patterns (no recording),
    # so composition stays functional.
    def track(name, &block)
      pattern = capture(&block)
      record_track(name, pattern, false)
      pattern
    end

    # Muted track: recorded under its name (so unmuting is deleting
    # one underscore) but bound as silence.
    def muted_track(name, &block)
      pattern = capture(&block)
      record_track(name, pattern, true)
      pattern
    end

    # True while a track block runs; bare sugar then stays pure.
    def capturing?
      @capturing > 0
    end

    # Record a bare statement into the next anonymous slot and return
    # a proxy so a method chain keeps updating that slot.
    def record_bare(pattern)
      index = @recording[:tracks].length
      anonymous = 0
      i = 0
      while i < index
        anonymous += 1 if @recording[:tracks][i][0].nil?
        i += 1
      end
      @recording[:tracks] << [nil, pattern, false, ("t" + (anonymous + 1).to_s).to_sym]
      TrackProxy.new(self, index, pattern)
    end

    def replace_bare(index, pattern)
      @recording[:tracks][index][1] = pattern
    end

    # -- Apply side: called from the app task after the sandbox
    # finished without an error. Returns false when there is nothing
    # to apply. --

    def apply
      recording = @recording
      return false unless recording
      @recording = nil
      Johakyu.build_patch = nil

      # Swap the rig first so the engine frame length follows before
      # any rebound track fires. A recording without fixture
      # statements keeps the current patch.
      if recording[:patch]
        Johakyu.patch = recording[:patch]
        ::DMX.active_slots = recording[:patch].max_channel
      end

      if recording[:tempo] && recording[:tempo] != @session.clock.bpm
        @session.tempo(recording[:tempo])
      end
      if recording[:latency] && recording[:latency] != @session.audio_latency_ms
        @session.audio_latency_ms = recording[:latency]
      end

      entries = recording[:tracks]
      bound = {}
      i = 0
      while i < entries.length
        entry = entries[i]
        i += 1
        name = entry[0] || entry[3]
        pattern = entry[2] ? Pattern.silence : entry[1]
        @session.bind_statement(name, pattern)
        bound[name] = true
      end

      # Replace semantics: tracks from the previous apply that this
      # recording no longer binds are removed. Their last DMX values
      # stay on the wire; bind a zero pattern to switch a light off.
      stale = @applied.keys
      i = 0
      while i < stale.length
        name = stale[i]
        i += 1
        @session.remove_statement(name) unless bound[name]
      end
      @applied = bound
      true
    end

    private

    def capture(&block)
      @capturing += 1
      begin
        pattern = block.call
      ensure
        @capturing -= 1
      end
      unless pattern.is_a?(Pattern)
        raise ArgumentError, "track block must return a Pattern"
      end
      pattern
    end

    def record_track(name, pattern, muted)
      raise ArgumentError, "track name must be a Symbol" unless name.is_a?(Symbol)
      @recording[:tracks] << [name, pattern, muted, nil]
    end
  end

  # Chain handle for bare statements: every call replaces the slot's
  # pattern with the transformed one, so the final link wins. Inside
  # track blocks this proxy never appears (sugar returns Patterns).
  class TrackProxy
    def initialize(live, index, pattern)
      @live = live
      @index = index
      @pattern = pattern
    end

    def fast(factor)
      replace(@pattern.fast(factor))
    end

    def slow(factor)
      replace(@pattern.slow(factor))
    end

    def rev
      replace(@pattern.rev)
    end

    def every(n, &func)
      replace(@pattern.every(n, &func))
    end

    def euclid(pulses, steps, rotation = 0)
      replace(@pattern.euclid(pulses, steps, rotation))
    end

    def struct(bool_pattern)
      replace(@pattern.struct(bool_pattern))
    end

    def mask(bool_pattern)
      replace(@pattern.mask(bool_pattern))
    end

    def degrade_by(amount)
      replace(@pattern.degrade_by(amount))
    end

    def degrade
      replace(@pattern.degrade)
    end

    def late(amount)
      replace(@pattern.late(amount))
    end

    def early(amount)
      replace(@pattern.early(amount))
    end

    def segment(n)
      replace(@pattern.segment(n))
    end

    def range(min, max)
      replace(@pattern.range(min, max))
    end

    def on(target)
      replace(@pattern.on(target))
    end

    def spread(amount, on: :all)
      replace(@pattern.spread(amount, on: on))
    end

    # One mirror per light control; the transforms above stay explicit
    # because their arities differ.
    LIGHT_CONTROLS.each do |key|
      define_method(key) { |source| replace(@pattern.send(key, source)) }
    end

    private

    def replace(pattern)
      @pattern = pattern
      @live.replace_bare(@index, pattern)
      self
    end
  end

  # Builder for the dmx(:s1).dimmer(...) sugar at the live top level:
  # the first attribute call builds the pattern and records it (bare)
  # or returns it (inside a track block).
  class LiveDmxBuilder
    def initialize(live, target)
      Johakyu.dmx(target) # unknown fixtures fail at record time
      @live = live
      @target = target
    end

    LIGHT_CONTROLS.each do |key|
      define_method(key) { |source| build(key, source) }
    end

    private

    def build(key, source)
      pattern = Johakyu.control_source(key, source).on(@target)
      @live.capturing? ? pattern : @live.record_bare(pattern)
    end
  end
end

# Top-level DSL for eval scripts. The johakyu app assigns the Live
# instance to $johakyu_live; scripts then read with no receiver.
# Statement sugar records bare statements as anonymous tracks (:t1,
# :t2, ...) unless it runs inside a track block, where it returns
# plain Patterns. Signal and pattern helpers are pure.

def tempo(bpm)
  $johakyu_live.tempo(bpm)
end

def audio_latency(ms)
  $johakyu_live.audio_latency(ms)
end

def fixture(name, file, mode: nil, address:)
  $johakyu_live.fixture(name, file, mode: mode, address: address)
end

def group(name, *members)
  $johakyu_live.group(name, *members)
end

def track(name, &block)
  $johakyu_live.track(name, &block)
end

def _track(name, &block)
  $johakyu_live.muted_track(name, &block)
end

def sound(source)
  pattern = Johakyu.sound(source)
  $johakyu_live.capturing? ? pattern : $johakyu_live.record_bare(pattern)
end

# One top-level statement per light control, the same shape as sound:
# pure inside track blocks, recorded as a bare statement otherwise.
Johakyu::LIGHT_CONTROLS.each do |key|
  define_method(key) do |source|
    pattern = Johakyu.control_source(key, source)
    $johakyu_live.capturing? ? pattern : $johakyu_live.record_bare(pattern)
  end
end

def dmx(target)
  Johakyu::LiveDmxBuilder.new($johakyu_live, target)
end

def sine
  Johakyu.sine
end

def saw
  Johakyu.saw
end

def isaw
  Johakyu.isaw
end

def tri
  Johakyu.tri
end

def cosine
  Johakyu.cosine
end

def euclid(pulses, steps, rotation = 0)
  Johakyu.euclid(pulses, steps, rotation)
end

def mini(text)
  Johakyu.mini(text)
end

def stack(*items)
  Johakyu::Pattern.stack(*items)
end

def silence
  Johakyu::Pattern.silence
end
