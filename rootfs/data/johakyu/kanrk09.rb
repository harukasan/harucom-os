
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# 四つ打ち
# The flash keeps 375 ms between the on and the off write: the
# scheduler can stall for one staging chunk (~250 ms), and a "[1 0]"
# pair inside one stall fires both writes back to back, swallowing
# the flash. "~" slots write nothing, so the off lands 3/16 cycle
# after the on and survives the stall.
_track(:drums) { sound("bd*4") }
_track(:flash) { dimmer("[1 ~ ~ 0]*4").color("white").on(:all) }

# Pan value where each beam hits stage center, measured on the rig
# (0.667 = one full turn on the 540 degree pan). Adjust with
# track(:aim) { pan(0.66).on(:s1) } before the show.
C1 = 0.66
C2 = 0.66
pan_swing = 0.05

# Pan/Tilt Speed (CH5): 0 = instant jumps, 1 = slowest glide. The
# fixture interpolates between the 8 targets per cycle, smoothing
# both the segment steps and the staging stalls. Raise toward 0.3 if
# still steppy; too high and the head lags and the ellipse shrinks.
pt_speed = 0.15

# Mirrored ellipse: same signals, s2 pan bounds reversed.
# One statement is one staging atom (queried in a single scheduler
# tick), so pan and tilt live in separate tracks: two short stalls
# with event pumps between them instead of one long stall that
# delays the flash writes.
_track(:left_pan) do
  dmx(:s1).speed(pt_speed)
          .pan(sine.range(C1 - pan_swing, C1 + pan_swing).slow(8))
end

_track(:left_tilt) do
  dmx(:s1).tilt(cosine.range(0.30, 0.50).slow(8))
end

_track(:right_pan) do
  dmx(:s2).speed(pt_speed)
          .pan(sine.range(C2 + pan_swing, C2 - pan_swing).slow(8))
end

_track(:right_tilt) do
  dmx(:s2).tilt(cosine.range(0.30, 0.50).slow(8))
end

_track(:center1) do
  dmx(:s1).pan("0.66").dimmer("0.1")
end

_track(:center2) do
  dmx(:s2).pan("0.66").dimmer("0.1")
end
