require "johakyu/live"

DMX.init
DMX.start
DMX.deadman_ms = 500

session = Johakyu::Session.new(bpm: 120)
live = Johakyu::Live.new(session)
$johakyu_live = live

# 円の中心と半径 (pan/tilt を 0.0〜1.0 で指定)。
CX = 0.67   # pan 中心 (≒ 正面, coarse 171)
CY = 0.30   # tilt 中心
R  = 0.15   # 半径

# 台本を録って一括適用。fixture/group で patch し、pan/tilt に位相 90°
# ずれの連続シグナルをあてると円になる。slow(2) が一周の遅さ。
live.begin_recording
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2
track(:circle) do
  dmx(:all).pan(cosine.range(CX - R, CX + R).slow(2))
           .tilt(sine.range(CY - R, CY + R).slow(2))
           .dimmer(1.0)
end
live.apply

# session が円運動を進め、keepalive がデッドマンを抑える。
loop do
  session.update
  DMX.keepalive
  sleep_ms 10
end
