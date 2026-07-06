# Johakyu master clock: a free-running timer read as a cycle position.
#
# Ruby reads Machine.board_millis (ms) only; there is no maintenance
# task and no dependency on the audio engine, so patterns keep running
# even if audio stalls. Millisecond resolution is enough for the 60 Hz
# scheduler tick and the 40 Hz DMX frame quantization.
#
# Tempo changes rebase the origin so the cycle position stays
# continuous (no jump in running patterns).

module Johakyu
  class Clock
    attr_reader :bpm, :beats_per_cycle

    def initialize(bpm: 120, beats_per_cycle: 4)
      @bpm = bpm
      @beats_per_cycle = beats_per_cycle
      @ms_per_cycle = 60_000.0 / bpm * beats_per_cycle
      @origin_ms = Machine.board_millis
      @origin_position = 0.0
    end

    def ms_per_cycle
      @ms_per_cycle
    end

    # Monotonic cycle position (Float).
    def position
      @origin_position + (Machine.board_millis - @origin_ms) / @ms_per_cycle
    end

    # Absolute board_millis at which a cycle position falls due.
    # Accepts Float or Fraction.
    def position_to_ms(position)
      @origin_ms + (position.to_f - @origin_position) * @ms_per_cycle
    end

    def bpm=(bpm)
      rebase
      @bpm = bpm
      @ms_per_cycle = 60_000.0 / bpm * @beats_per_cycle
    end

    # Cycles per minute (strudel setcpm equivalent).
    def cpm=(cpm)
      rebase
      @ms_per_cycle = 60_000.0 / cpm
      @bpm = cpm * @beats_per_cycle
    end

    # Cycles per second (strudel setcps equivalent).
    def cps=(cps)
      rebase
      @ms_per_cycle = 1000.0 / cps
      @bpm = cps * 60.0 * @beats_per_cycle
    end

    private

    # Anchor the current position so a tempo change is continuous.
    def rebase
      now = Machine.board_millis
      @origin_position = @origin_position + (now - @origin_ms) / @ms_per_cycle
      @origin_ms = now
    end
  end
end
