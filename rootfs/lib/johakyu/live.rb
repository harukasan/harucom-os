# Johakyu live coding layer: pure recording of an eval script, applied
# to the running session afterwards (research 06).
#
# The johakyu app evaluates the editor buffer in a resident Sandbox
# task. That task must not touch the running Session directly: the
# scheduler arrays are mutated by the app task on every update, and a
# preemptive task switch mid-mutation would corrupt them. Instead the
# script talks to a Live recorder through top-level DSL methods
# (tempo/sound/dmx), which only build Patterns and record intents,
# both side-effect free. When the sandbox finishes cleanly the app
# task calls Live#apply, which replays the recording onto the Session;
# the scheduler's quantized swap makes the change land at the next
# cycle boundary. If the script raised, the recording is discarded and
# the show keeps playing the previous patterns.
#
# Each eval describes the whole desired state, like a Strudel buffer:
# tracks bound by a previous apply but absent from the new recording
# are removed. An empty buffer therefore silences everything.
#
#   tempo 130
#   sound("bd*2 [~ sn] bd sn, hh*8").every(4) { |p| p.rev }
#   dmx(:s1).dimmer("1 0 0.5 0").color("<red blue>")
#   dmx(:s2).pan(sine.range(0.3, 0.7).slow(8))

require "johakyu/dsl"

module Johakyu
  class Live
    attr_reader :session

    def initialize(session)
      @session = session
      @recording = nil
      @applied_sound = false
      @applied_dmx = {}
    end

    # Start a fresh recording. Call from the app task right before
    # executing the eval script.
    def begin_recording
      @recording = { tempo: nil, latency: nil, sound: nil, dmx: [] }
    end

    def recording?
      @recording != nil
    end

    # Drop the recording without applying (script raised or timed out).
    def discard
      @recording = nil
    end

    # -- Recorder side: called from the eval script (sandbox task). --
    # These only validate and record; nothing reaches the Session.

    def tempo(bpm)
      @recording[:tempo] = bpm
    end

    def audio_latency(ms)
      @recording[:latency] = ms
    end

    # Same shape as Session#sound: reify, remember, hand out the
    # chainable handle. SoundHandle only calls transform_sound, so the
    # recorder can stand in for the Session.
    def sound(pattern)
      @recording[:sound] = Pattern.reify(pattern)
      Session::SoundHandle.new(self)
    end

    def transform_sound(&block)
      return unless @recording && @recording[:sound]
      @recording[:sound] = block.call(@recording[:sound])
    end

    # DmxTarget only calls bind_dmx, so it chains over the recorder
    # too. Resolving the target here surfaces unknown fixture names as
    # a script error instead of a broken apply.
    def dmx(target)
      Johakyu.dmx(target)
      Session::DmxTarget.new(self, target)
    end

    def bind_dmx(target, attribute, pattern)
      @recording[:dmx] << [target, attribute, pattern]
    end

    # -- Apply side: called from the app task after the sandbox
    # finished without an error. Returns false when there is nothing
    # to apply. --

    def apply
      recording = @recording
      return false unless recording
      @recording = nil

      if recording[:tempo] && recording[:tempo] != @session.clock.bpm
        @session.tempo(recording[:tempo])
      end
      if recording[:latency] && recording[:latency] != @session.audio_latency_ms
        @session.audio_latency_ms = recording[:latency]
      end

      if recording[:sound]
        @session.sound(recording[:sound])
        @applied_sound = true
      elsif @applied_sound
        @session.sound(Pattern.silence)
        @applied_sound = false
      end

      binds = recording[:dmx]
      new_tracks = {}
      i = 0
      while i < binds.length
        bind = binds[i]
        i += 1
        @session.bind_dmx(bind[0], bind[1], bind[2])
        new_tracks[Session.dmx_track_name(bind[0], bind[1])] = true
      end

      # Replace semantics: tracks from the previous apply that this
      # recording no longer binds are removed. Their last DMX values
      # stay on the wire; bind a zero pattern to switch a light off.
      stale = @applied_dmx.keys
      i = 0
      while i < stale.length
        track = stale[i]
        i += 1
        @session.scheduler.remove(track) unless new_tracks[track]
      end
      @applied_dmx = new_tracks
      true
    end
  end
end

# Top-level DSL for eval scripts. The johakyu app assigns the Live
# instance to $johakyu_live; scripts then read like the research 05
# examples with no receiver. Signal and pattern helpers are pure, so
# they delegate straight to the Johakyu module.

def tempo(bpm)
  $johakyu_live.tempo(bpm)
end

def audio_latency(ms)
  $johakyu_live.audio_latency(ms)
end

def sound(pattern)
  $johakyu_live.sound(pattern)
end

def dmx(target)
  $johakyu_live.dmx(target)
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
