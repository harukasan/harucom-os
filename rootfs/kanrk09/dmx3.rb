require "johakyu/fixture"

spot = Johakyu.personality("shehds_80w_led_spot_light", "13ch")
patch = Johakyu::Patch.new
patch.add(:s1, spot, base: 1)
patch.add(:s2, spot, base: 14)
patch.group(:all, :s1, :s2)
Johakyu.patch = patch

DMX.init
DMX.start
DMX.active_slots = patch.max_channel

# 円の中心と半径 (pan/tilt を 0.0〜1.0 で指定)。
CX = 0.67   # pan 中心 (≒ 正面, coarse 171)
CY = 0.30   # tilt 中心
R  = 0.15   # 半径

t = 0.0
loop do
  Johakyu.dmx(:all)
    .pan(CX + R * Math.cos(t))
    .tilt(CY + R * Math.sin(t))
    .dimmer(1.0)
  DMX.keepalive
  t += 0.05
  sleep_ms 20
end
