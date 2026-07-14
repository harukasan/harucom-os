# kanrk09: four-on-the-floor and a mirrored ellipse, all muted.
# Unmute a part by deleting the leading underscore of its _track and
# pressing Ctrl-Enter; it joins at the next cycle boundary.

fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# Pan value where each beam hits stage center, measured on the rig
# (0.667 = one full turn on the 540 degree pan). Adjust with
# track(:aim) { pan(0.66).on(:s1) } before the show.
pan_center_s1 = 0.66
pan_center_s2 = 0.66
pan_swing = 0.05

_track(:drums) { sound("bd*4") }
_track(:flash) { dimmer("[1 0]*4").color("white").on(:all) }

# Mirrored ellipse: same signals, s2 pan bounds reversed.
_track(:left) do
  dmx(:s1).pan(sine.range(pan_center_s1 - pan_swing, pan_center_s1 + pan_swing).slow(8))
          .tilt(cosine.range(0.30, 0.50).slow(8))
end

_track(:right) do
  dmx(:s2).pan(sine.range(pan_center_s2 + pan_swing, pan_center_s2 - pan_swing).slow(8))
          .tilt(cosine.range(0.30, 0.50).slow(8))
end
