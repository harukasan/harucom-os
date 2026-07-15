
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# 四つ打ち
_track(:drums) { sound("bd*4") }
_track(:flash) { dimmer("[1 ~ ~ 0]*4").color("white").on(:all) }

C1 = 0.667
C2 = 0.667
P = 0.05

_track(:left) do
  dmx(:s1).pan(sine.range(C1 - P, C1 + P).slow(4))
          .tilt(cosine.range(0.30, 0.50).slow(4))
end

_track(:right) do
  dmx(:s2).pan(sine.range(C2 + P, C2 - P).slow(8))
          .tilt(cosine.range(0.30, 0.50).slow(8))
end

_track(:center1) do
  dmx(:s1).pan("#{C1}")
end

_track(:center2) do
  dmx(:s2).pan("#{C2}")
end
