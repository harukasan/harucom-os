# 想いが今、光になる……
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

stream :song, address: 0x10440000, bytes: 1826184, channel: 6, volume: 15

tempo 140

def section_cat(entries)
  bars = []
  e = 0
  while e < entries.length
    pattern = entries[e][0]
    count = entries[e][1]
    e += 1
    i = 0
    while i < count
      bars << (pattern.is_a?(Array) ? pattern[i % pattern.length] : pattern)
      i += 1
    end
  end
  Johakyu::Pattern.slowcat(*bars)
end

def hold(value)
  Johakyu::Pattern.pure(value)
end

rest = Johakyu::Pattern.silence

dimmer_path = [
  [mini("0"), 3],
  [mini("[1 ~ ~ 0]*2"), 8],
  [mini("0.25"), 12],
  [mini("[0.7 0.2 0.5 0.2]"), 11],
  [mini("[1 ~ ~ 0]*4"), 17],
  [mini("[1 0.3 0.7 0.3]"), 10],
  [mini("[1 ~ 0.6 0]*4"), 12],
  [mini("1"), 1],
  [mini("0.3"), 1],
  [mini("0"), 1],
  [rest, 284],
]

color_path = [
  [hold("white"), 3],
  [hold("blue"), 8],
  [hold("blue"), 12],
  [hold("yellow"), 11],
  [[hold("red"), hold("white")], 17],
  [[hold("yellow"), hold("pink")], 10],
  [[hold("red"), hold("white"), hold("yellow"), hold("pink")], 12],
  [hold("white"), 1],
  [hold("blue"), 1],
  [hold("white"), 1],
  [rest, 284],
]

# Motion

pan_left = [
  [hold(0.667), 11],
  [sine.range(0.60, 0.73).slow(8).segment(16), 23],
  [sine.range(0.60, 0.73).slow(2).segment(16), 39],
  [hold(0.667), 1],
  [rest, 286],
]

pan_right = [
  [hold(0.667), 11],
  [sine.range(0.73, 0.60).slow(8).segment(16), 23],
  [sine.range(0.73, 0.60).slow(2).segment(16), 39],
  [hold(0.667), 1],
  [rest, 286],
]

tilt_path = [
  [hold(0.141), 11],
  [hold(0.141), 23],
  [cosine.range(0.0, 0.3).slow(2).segment(16), 39],
  [hold(0.141), 1],
  [rest, 286],
]

prism_path = [
  [hold(0), 34],
  [hold(180), 39],
  [hold(0), 1],
  [rest, 286],
]

# Pan/Tilt Speed: high is slow on this fixture. The opening travel to
# center is slow and stately, then the show runs fast from the intro.
speed_path = [
  [hold(0.8), 3],
  [hold(0.15), 71],
  [rest, 286],
]

song_hit = Johakyu::Pattern.slowcat(Johakyu::Pattern.pure("song"),
                                    *([Johakyu::Pattern.silence] * 359))

track(:song) { sound(song_hit) }

track(:flash) do
  dimmer(section_cat(dimmer_path)).color(section_cat(color_path)).on(:all)
end

track(:left) do
  dmx(:s1).pan(section_cat(pan_left))
          .tilt(section_cat(tilt_path))
          .prism(section_cat(prism_path))
          .speed(section_cat(speed_path))
end

track(:right) do
  dmx(:s2).pan(section_cat(pan_right))
          .tilt(section_cat(tilt_path))
          .prism(section_cat(prism_path))
          .speed(section_cat(speed_path))
end

_track(:center) do
  Johakyu::Pattern.stack(
    dmx(:s1).pan(106).tilt(30).focus(138).dimmer(1.0).color("white"),
    dmx(:s2).pan(55).tilt(24).focus(168).dimmer(1.0).color("white")
  ).fast(2)
end
