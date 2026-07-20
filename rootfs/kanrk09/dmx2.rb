require "board/dmx"

dmx = Board::DMX.new
dmx.start
loop do
  t = Machine.board_millis / 1000.0
  [1, 14].each_with_index do |b, i|
    dir = i.zero? ? 1 : -1
    dmx[b]     = 171 + (40 * Math.sin(t * 0.7) * dir).to_i  # Pan (171=正面)
    dmx[b + 2] = 41 + (29 * Math.sin(t * 1.1)).to_i        # Tilt (12〜70)
    dmx[b + 5] = 255
  end
  dmx.keepalive
  sleep_ms 20
end
