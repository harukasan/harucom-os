# Hardware stubs for host tests. Loaded into the target VM (microruby)
# before each test file, replacing the board's C modules so rootfs
# scripts run unmodified. Tests control time through Machine.millis=.

module Machine
  def self.board_millis
    $machine_millis || 0
  end

  def self.millis=(ms)
    $machine_millis = ms
  end
end

# DMX universe stub with a write log for timing assertions.
module DMX
  def self.reset
    $dmx_universe = nil
    $dmx_writes = nil
  end

  def self.universe
    $dmx_universe ||= Array.new(513, 0)
  end

  def self.writes
    $dmx_writes ||= []
  end

  def self.set(channel, value)
    universe[channel] = value
    writes << [Machine.board_millis, channel, value]
  end

  def self.set_range(channel, values)
    i = 0
    while i < values.length
      set(channel + i, values[i])
      i += 1
    end
  end

  def self.get(channel)
    universe[channel]
  end

  def self.blackout
    ch = 1
    while ch <= 512
      universe[ch] = 0
      ch += 1
    end
  end
end

module PWMAudio
  SINE = 0
  SQUARE = 1
  TRIANGLE = 2
  SAWTOOTH = 3
end

# Records tone/stop calls with the stubbed time for assertions.
class FakeAudio
  attr_reader :events

  def initialize
    @events = []
  end

  def tone(channel, frequency, waveform: 0, volume: 15)
    @events << [:tone, Machine.board_millis, channel, frequency, volume]
  end

  def stop(channel)
    @events << [:stop, Machine.board_millis, channel]
  end

  def stop_all
  end

  def update
  end

  # Sample clock anchored to the stubbed millis at the engine rate, so
  # reservation math in tests resolves to target_ms * 50 exactly.
  def sample_clock
    Machine.board_millis * 50
  end

  def play_at(sample, channel, volume = 15)
    @events << [:play_at, sample, channel, volume]
    true
  end

  def tones
    @events.select { |e| e[0] == :tone }
  end

  def stops
    @events.select { |e| e[0] == :stop }
  end

  def plays
    @events.select { |e| e[0] == :play_at }
  end
end

# Render a hap list as comparable strings: "whole|part|value" with
# fraction times as n/d. Keeps expectations readable in assert_equal.
def hap_sigs(haps)
  result = []
  i = 0
  while i < haps.length
    hap = haps[i]
    i += 1
    whole = hap.whole ? "#{frac_s(hap.whole.begin_time)}..#{frac_s(hap.whole.end_time)}" : "nil"
    part = "#{frac_s(hap.part.begin_time)}..#{frac_s(hap.part.end_time)}"
    result << "#{whole}|#{part}|#{hap.value.inspect}"
  end
  result
end

def frac_s(fraction)
  "#{fraction.num}/#{fraction.den}"
end
